//
//  GuildViews.swift
//  Endgame Fitness
//
//  Copyright (c) 2026 Daniel Bates / Bates LLC. All rights reserved.
//  https://batesai.org · help@batesai.org
//
//  Guilds (API_V2 §5): join with an invite code, browse open guilds, start
//  one, share the code, and — for owners — rotate the code and edit the
//  guild. Members share the weekly raid boss, so a guild is only worth having
//  once other people can actually get in.
//

import SwiftUI

/// Emblems a guild can pick. Emoji keep it light and need no artwork.
enum GuildEmblems {
    static let choices = ["🛡️", "⚔️", "🔥", "🐺", "🦁", "🐉", "⚡", "🏔️", "🌊", "🦅", "🌙", "⭐"]
}

struct GuildEmblemView: View {
    let emblem: String?
    var size: CGFloat = 44

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.25)
                .fill(LinearGradient(colors: [Color.brandPurple.opacity(0.35), Color.brandBlue.opacity(0.2)],
                                     startPoint: .topLeading, endPoint: .bottomTrailing))
            if let emblem, !emblem.isEmpty, emblem.count <= 2 {
                Text(emblem).font(.system(size: size * 0.5))
            } else {
                Image(systemName: "shield.lefthalf.filled")
                    .font(.system(size: size * 0.45))
                    .foregroundStyle(.white)
            }
        }
        .frame(width: size, height: size)
    }
}

// MARK: - Pane

struct GuildPane: View {
    @ObservedObject var game = GameProfileService.shared
    let open: (CommunitySheet) -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                if let guild = game.guild {
                    GuildHomeView(guild: guild, open: open)
                } else {
                    NoGuildView(open: open)
                    // No guild: the weekly boss is a solo raid.
                    RaidCard()
                }
            }
            .padding(16)
        }
        .refreshable { await game.loadGuild() }
    }
}

// MARK: - In a guild

struct GuildHomeView: View {
    let guild: Guild
    let open: (CommunitySheet) -> Void

    @ObservedObject var game = GameProfileService.shared
    @State private var showEdit = false
    @State private var confirmLeave = false
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            GuildInviteCard(guild: guild)
            // Weekly co-op boss: every member's synced training is damage.
            RaidCard()
            members
            if let error {
                Text(error).font(.caption).foregroundStyle(.red)
            }
            Button("Leave guild", role: .destructive) { confirmLeave = true }
                .padding(.top, 8)
        }
        .sheet(isPresented: $showEdit) { GuildEditSheet(guild: guild) }
        .confirmationDialog("Leave \(guild.name)?", isPresented: $confirmLeave, titleVisibility: .visible) {
            Button("Leave guild", role: .destructive) {
                Task { error = await game.leaveGuild() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(game.isGuildOwner
                 ? "You own this guild. Ownership passes to the longest-serving member; if you're the last one, the guild is deleted."
                 : "You can rejoin later with an invite code, or from the open list if the guild is open.")
        }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 14) {
            GuildEmblemView(emblem: guild.emblem, size: 56)
            VStack(alignment: .leading, spacing: 4) {
                Text(guild.name).font(.title2.bold())
                if let motto = guild.motto, !motto.isEmpty {
                    Text(motto).font(.callout).foregroundStyle(.secondary)
                }
                HStack(spacing: 8) {
                    Text("\(game.guildMembers.count) / \(guild.memberCap) members")
                    Text(guild.isOpen ? "Open to anyone" : "Invite only")
                        .padding(.horizontal, 6).padding(.vertical, 1)
                        .background(Capsule().fill(Color.gray.opacity(0.15)))
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            if game.isGuildOwner {
                Button("Edit") { showEdit = true }
                    .buttonStyle(.bordered)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.platformControlBackground)
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    private var members: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Members").font(.headline).padding(.bottom, 4)
            ForEach(game.guildMembers) { member in
                Button {
                    if member.userID != game.profile?.userID {
                        open(.player(PlayerRef(id: member.userID, displayName: member.displayName)))
                    }
                } label: {
                    GuildMemberRow(member: member, isSelf: member.userID == game.profile?.userID)
                }
                .buttonStyle(.plain)
            }
        }
    }
}

struct GuildMemberRow: View {
    let member: GuildMember
    let isSelf: Bool

    var body: some View {
        HStack(spacing: 10) {
            AvatarBadgeView(config: nil, level: member.level, size: 30,
                            tint: FitnessProfile.rankColor(for: member.level))
            Text(isSelf ? "\(member.displayName) (you)" : member.displayName)
                .fontWeight(.medium)
                .lineLimit(1)
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
        .contentShape(Rectangle())
    }
}

struct GuildInviteCard: View {
    let guild: Guild

    @ObservedObject var game = GameProfileService.shared
    @State private var copied = false
    @State private var confirmRotate = false
    @State private var isRotating = false
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let code = guild.inviteCode, !code.isEmpty {
                HStack(spacing: 10) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Invite code").font(.caption).foregroundStyle(.secondary)
                        Text(code)
                            .font(.system(.title2, design: .monospaced).weight(.bold))
                            .tracking(2)
                            .textSelection(.enabled)
                    }
                    Spacer()
                    Button(copied ? "Copied" : "Copy") {
                        Platform.copyToClipboard(code)
                        copied = true
                        Task { try? await Task.sleep(nanoseconds: 1_500_000_000); copied = false }
                    }
                    ShareLink(item: "Join my guild \(guild.name) on Endgame Fitness. Invite code: \(code)") {
                        Image(systemName: "square.and.arrow.up")
                    }
                    .accessibilityLabel("Share invite code")
                }
                HStack {
                    Text("Anyone with this code can join, up to \(guild.memberCap) members.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    if game.canManageInvites {
                        Button(isRotating ? "Changing…" : "New code") { confirmRotate = true }
                            .font(.caption)
                            .disabled(isRotating)
                    }
                }
            } else {
                Text("This guild doesn't have an invite code yet.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if let error {
                Text(error).font(.caption).foregroundStyle(.red)
            }
        }
        .padding(14)
        .background(Color.brandPurple.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .confirmationDialog("Make a new invite code?", isPresented: $confirmRotate, titleVisibility: .visible) {
            Button("New code") {
                Task {
                    isRotating = true
                    error = await game.rotateGuildInviteCode()
                    isRotating = false
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The old code stops working. People already in the guild stay.")
        }
    }
}

// MARK: - Not in a guild

struct NoGuildView: View {
    let open: (CommunitySheet) -> Void

    @ObservedObject var game = GameProfileService.shared

    @State private var inviteCode = ""
    @State private var joinError: String?
    @State private var isJoining = false

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            CommunityEmptyState(
                icon: "shield.lefthalf.filled",
                title: "You're not in a guild",
                message: "A guild is a crew of up to 50 who share a leaderboard and fight a raid boss every week with their training."
            )
            joinByCode
            GuildDiscoveryList(open: open)
            CreateGuildForm()
        }
    }

    private var trimmedCode: String { inviteCode.trimmingCharacters(in: .whitespacesAndNewlines) }

    private var joinByCode: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Have an invite code?").font(.headline)
            HStack(spacing: 8) {
                PlatformTextField(placeholder: "Invite code", text: $inviteCode, onCommit: join)
                Button(isJoining ? "Joining…" : "Join", action: join)
                    .buttonStyle(.borderedProminent)
                    .tint(.brandPurple)
                    .disabled(trimmedCode.count < 4 || isJoining)
            }
            if let joinError {
                Text(joinError).font(.caption).foregroundStyle(.red)
            }
        }
    }

    private func join() {
        guard trimmedCode.count >= 4, !isJoining else { return }
        isJoining = true
        Task {
            joinError = await game.joinGuild(inviteCode: trimmedCode)
            if joinError == nil { inviteCode = "" }
            isJoining = false
        }
    }
}

struct GuildDiscoveryList: View {
    let open: (CommunitySheet) -> Void

    @ObservedObject var game = GameProfileService.shared

    @State private var query = ""
    @State private var guilds: [GuildSummary] = []
    @State private var isLoading = false
    @State private var error: String?
    @State private var joining: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Open guilds").font(.headline)
            HStack(spacing: 8) {
                PlatformTextField(placeholder: "Search guilds", text: $query, onCommit: { Task { await search() } })
                Button("Search") { Task { await search() } }
                    .disabled(isLoading)
            }
            if isLoading {
                SwiftUI.ProgressView().controlSize(.small)
            } else if let error {
                Text(error).font(.caption).foregroundStyle(.red)
            } else if guilds.isEmpty {
                Text(query.isEmpty ? "No open guilds yet. Start one below." : "No open guilds match \"\(query)\".")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            ForEach(guilds) { guild in
                GuildSummaryRow(
                    guild: guild,
                    isJoining: joining == guild.id,
                    onJoin: { Task { await join(guild) } },
                    onReport: {
                        open(.report(ReportRequest(target: .guild, targetID: guild.id, subject: "the guild \(guild.name)")))
                    }
                )
            }
        }
        .task { await search() }
    }

    private func search() async {
        isLoading = true
        defer { isLoading = false }
        do {
            guilds = try await game.discoverGuilds(query: query)
            error = nil
        } catch {
            guilds = []
            self.error = error.localizedDescription
        }
    }

    private func join(_ guild: GuildSummary) async {
        joining = guild.id
        error = await game.joinGuild(id: guild.id)
        joining = nil
    }
}

struct GuildSummaryRow: View {
    let guild: GuildSummary
    let isJoining: Bool
    let onJoin: () -> Void
    let onReport: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            GuildEmblemView(emblem: guild.emblem, size: 38)
            VStack(alignment: .leading, spacing: 2) {
                Text(guild.name).fontWeight(.semibold).lineLimit(1)
                if let motto = guild.motto, !motto.isEmpty {
                    Text(motto).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                Text("\(guild.memberCount) members").font(.caption2).foregroundStyle(.secondary)
            }
            Spacer()
            Button(isJoining ? "Joining…" : "Join", action: onJoin)
                .buttonStyle(.bordered)
                .disabled(isJoining || guild.memberCount >= 50)
            Menu {
                Button(action: onReport) {
                    Label("Report guild…", systemImage: "exclamationmark.bubble")
                }
            } label: {
                Image(systemName: "ellipsis")
                    .foregroundStyle(.secondary)
                    .frame(width: 24, height: 24)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .accessibilityLabel("More actions for \(guild.name)")
        }
        .padding(10)
        .background(Color.platformControlBackground)
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }
}

struct CreateGuildForm: View {
    @ObservedObject var game = GameProfileService.shared

    @State private var name = ""
    @State private var motto = ""
    @State private var emblem = GuildEmblems.choices[0]
    @State private var isOpen = true
    @State private var isCreating = false
    @State private var error: String?

    private var trimmedName: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Start a guild").font(.headline)
            PlatformTextField(placeholder: "Guild name", text: $name)
            PlatformTextField(placeholder: "Motto (optional)", text: $motto)
            GuildEmblemPicker(selection: $emblem)
            Toggle("Open: anyone can find and join it", isOn: $isOpen)
                .font(.callout)
            Button(isCreating ? "Creating…" : "Create guild") {
                Task {
                    isCreating = true
                    error = await game.createGuild(name: trimmedName, motto: motto, emblem: emblem, isOpen: isOpen)
                    if error == nil { name = ""; motto = "" }
                    isCreating = false
                }
            }
            .buttonStyle(.borderedProminent)
            .tint(.brandPurple)
            .disabled(trimmedName.count < 2 || trimmedName.count > 32 || isCreating)
            if let error {
                Text(error).font(.caption).foregroundStyle(.red)
            }
        }
    }
}

struct GuildEmblemPicker: View {
    @Binding var selection: String

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(GuildEmblems.choices, id: \.self) { choice in
                    Button {
                        selection = choice
                    } label: {
                        Text(choice)
                            .font(.title3)
                            .frame(width: 36, height: 36)
                            .background(
                                RoundedRectangle(cornerRadius: 8)
                                    .fill(selection == choice ? Color.brandPurple.opacity(0.25) : Color.platformControlBackground)
                            )
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Emblem \(choice)")
                }
            }
        }
    }
}

// MARK: - Edit (owner)

struct GuildEditSheet: View {
    let guild: Guild

    @ObservedObject var game = GameProfileService.shared
    @Environment(\.dismiss) private var dismiss

    @State private var name = ""
    @State private var motto = ""
    @State private var emblem = GuildEmblems.choices[0]
    @State private var isOpen = true
    @State private var isSaving = false
    @State private var error: String?

    var body: some View {
        NavigationStack {
            Form {
                Section("Guild") {
                    TextField("Name", text: $name)
                    TextField("Motto", text: $motto)
                }
                Section("Emblem") {
                    GuildEmblemPicker(selection: $emblem)
                }
                Section {
                    Toggle("Open to anyone", isOn: $isOpen)
                } footer: {
                    Text(isOpen
                         ? "Open guilds appear in the guild list and anyone can join."
                         : "Invite-only guilds can be joined only with the invite code.")
                }
                if let error {
                    Section { Text(error).foregroundStyle(.red) }
                }
            }
            .formStyle(.grouped)
            .navigationTitle("Edit guild")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(isSaving ? "Saving…" : "Save") { Task { await save() } }
                        .disabled(isSaving || name.trimmingCharacters(in: .whitespacesAndNewlines).count < 2)
                }
            }
        }
        .desktopMinFrame(minWidth: 420, minHeight: 420)
        .onAppear {
            name = guild.name
            motto = guild.motto ?? ""
            emblem = guild.emblem ?? GuildEmblems.choices[0]
            isOpen = guild.isOpen
        }
    }

    private func save() async {
        var fields: [String: Any] = [:]
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedMotto = motto.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedName != guild.name { fields["name"] = trimmedName }
        if trimmedMotto != (guild.motto ?? "") { fields["motto"] = trimmedMotto }
        if emblem != (guild.emblem ?? "") { fields["emblem"] = emblem }
        if isOpen != guild.isOpen { fields["is_open"] = isOpen }
        guard !fields.isEmpty else { dismiss(); return }

        isSaving = true
        defer { isSaving = false }
        if let failure = await game.updateGuild(fields) {
            error = failure
        } else {
            dismiss()
        }
    }
}
