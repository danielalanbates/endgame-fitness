//
//  RaidViews.swift
//  Endgame Fitness
//
//  Guild Raids: a weekly boss every guild member damages with real training
//  volume. The server owns the fight (see App/Backend/functions/_lib/raids.js);
//  this file only draws it — boss art, an animated HP bar, the contributor
//  list, the player's own damage, a countdown to the weekly reset, and a
//  small "damage dealt" toast after a sync lands a hit.
//

import SwiftUI

// MARK: - Card

struct RaidCard: View {
    @ObservedObject var game = GameProfileService.shared

    /// The toast currently shown over the card, if any.
    @State private var toast: RaidHit?
    @State private var toastTask: Task<Void, Never>?

    var body: some View {
        Group {
            if let raid = game.raid {
                RaidBossPanel(raid: raid)
            } else if game.isLoadingRaid {
                HStack(spacing: 10) {
                    SwiftUI.ProgressView().controlSize(.small)
                    Text("Summoning this week's boss…")
                        .font(.callout).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(16)
                .background(Color.platformControlBackground)
                .clipShape(RoundedRectangle(cornerRadius: 12))
            } else {
                HStack(spacing: 10) {
                    Image(systemName: "shield.slash")
                        .foregroundStyle(.secondary)
                    Text("Couldn't load this week's boss.")
                        .font(.callout).foregroundStyle(.secondary)
                    Spacer()
                    Button("Retry") { Task { await game.loadRaid() } }
                        .font(.caption)
                }
                .padding(16)
                .background(Color.platformControlBackground)
                .clipShape(RoundedRectangle(cornerRadius: 12))
            }
        }
        .overlay(alignment: .top) {
            if let hit = toast {
                RaidDamageToast(hit: hit)
                    .padding(.top, 10)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .animation(.spring(response: 0.45, dampingFraction: 0.8), value: toast)
        .task { await game.loadRaid() }
        .onChange(of: game.lastRaidHit) { _, hit in
            guard let hit else { return }
            showToast(hit)
            game.lastRaidHit = nil
        }
        .onAppear {
            // A sync may have landed while another tab was showing.
            if let hit = game.lastRaidHit {
                showToast(hit)
                game.lastRaidHit = nil
            }
        }
    }

    private func showToast(_ hit: RaidHit) {
        toastTask?.cancel()
        toast = hit
        Platform.success()
        toastTask = Task {
            try? await Task.sleep(nanoseconds: (hit.justDefeated ? 5 : 3) * 1_000_000_000)
            if !Task.isCancelled { toast = nil }
        }
    }
}

// MARK: - Boss panel

struct RaidBossPanel: View {
    let raid: RaidState

    /// Animated separately from `raid` so the bar slides rather than snaps.
    @State private var shownFraction: Double = 1
    @State private var selectedPlayer: PlayerRef?

    private var gradient: LinearGradient {
        let colors = raid.boss.gradient.compactMap { Color(raidHex: $0) }
        return LinearGradient(
            colors: colors.count >= 2 ? colors : [Color.brandPurple, Color.brandBlue.opacity(0.4)],
            startPoint: .topLeading, endPoint: .bottomTrailing
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            hpBar
            stats
            if !raid.contributors.isEmpty {
                contributors
            } else {
                Text("No damage yet this week. Finish a workout to land the first hit.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.platformControlBackground)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(raid.defeated ? Color.brandGreen.opacity(0.6) : Color.clear, lineWidth: 1.5)
        )
        .onAppear { shownFraction = raid.hpFraction }
        .onChange(of: raid.hpFraction) { _, new in
            withAnimation(.easeOut(duration: 0.9)) { shownFraction = new }
        }
        .playerProfileSheet($selectedPlayer)
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 14) {
            RaidBossArt(symbol: raid.boss.symbol, gradient: gradient, defeated: raid.defeated)
                .frame(width: 72, height: 72)

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text("GUILD RAID")
                        .font(.caption2.weight(.black))
                        .foregroundStyle(.secondary)
                    if raid.defeated {
                        Text("DEFEATED")
                            .font(.caption2.weight(.black))
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(Color.brandGreen.opacity(0.18))
                            .foregroundStyle(Color.brandGreen)
                            .clipShape(Capsule())
                    }
                }
                Text(raid.boss.name)
                    .font(.headline)
                    .lineLimit(2)
                if let flavor = raid.boss.flavor, !flavor.isEmpty {
                    Text(flavor)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(3)
                }
            }
            Spacer(minLength: 0)
            RaidCountdown(endsAt: raid.endsAt, defeated: raid.defeated)
        }
    }

    private var hpBar: some View {
        VStack(alignment: .leading, spacing: 5) {
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.primary.opacity(0.08))
                    Capsule()
                        .fill(
                            LinearGradient(
                                colors: raid.defeated
                                    ? [Color.brandGreen, Color.brandGreen.opacity(0.6)]
                                    : [Color.red, Color.brandOrange],
                                startPoint: .leading, endPoint: .trailing
                            )
                        )
                        .frame(width: max(0, proxy.size.width * (raid.defeated ? 1 : shownFraction)))
                }
            }
            .frame(height: 12)

            HStack {
                Text(raid.defeated
                     ? "Boss down — \(RaidFormat.number(raid.hp)) HP cleared"
                     : "\(RaidFormat.number(raid.hpRemaining)) / \(RaidFormat.number(raid.hp)) HP")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                Spacer()
                Text("\(Int((1 - raid.hpFraction) * 100))%")
                    .font(.caption.weight(.semibold).monospacedDigit())
            }
        }
    }

    private var stats: some View {
        HStack(spacing: 10) {
            RaidStat(icon: "bolt.fill", tint: .brandYellow,
                     label: "Your damage", value: RaidFormat.number(raid.myDamage))
            RaidStat(icon: "figure.strengthtraining.traditional", tint: .brandBlue,
                     label: "Your hits", value: "\(raid.myHits)")
            RaidStat(icon: "star.fill", tint: .brandPurple,
                     label: "Reward", value: "+\(raid.boss.rewardXP) XP")
        }
    }

    private var contributors: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Top contributors")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            ForEach(raid.contributors) { entry in
                Button {
                    if !entry.isSelf {
                        selectedPlayer = PlayerRef(id: entry.userID, displayName: entry.displayName)
                    }
                } label: {
                    contributorRow(entry)
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func contributorRow(_ entry: RaidContributor) -> some View {
        HStack(spacing: 10) {
            Text("\(entry.rank)")
                .font(.caption.weight(.bold).monospacedDigit())
                .frame(width: 18, alignment: .trailing)
                .foregroundStyle(entry.rank == 1 ? Color.brandYellow : .secondary)
            Text(entry.isSelf ? "You" : entry.displayName)
                .font(.callout)
                .fontWeight(entry.isSelf ? .semibold : .regular)
                .lineLimit(1)
            Text("Lv \(entry.level)")
                .font(.caption2).foregroundStyle(.secondary)
            Spacer()
            Text(RaidFormat.number(entry.damage))
                .font(.callout.monospacedDigit())
            Text("dmg")
                .font(.caption2).foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
    }
}

// MARK: - Pieces

struct RaidBossArt: View {
    let symbol: String
    let gradient: LinearGradient
    let defeated: Bool

    @State private var breathe = false

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 16)
                .fill(gradient)
            RoundedRectangle(cornerRadius: 16)
                .stroke(Color.white.opacity(0.18), lineWidth: 1)
            Image(systemName: symbol)
                .font(.system(size: 32, weight: .bold))
                .foregroundStyle(.white)
                .shadow(color: .black.opacity(0.35), radius: 4, y: 2)
                .scaleEffect(breathe ? 1.06 : 0.96)
                .animation(.easeInOut(duration: 1.4).repeatForever(autoreverses: true), value: breathe)
            if defeated {
                Image(systemName: "xmark")
                    .font(.system(size: 46, weight: .black))
                    .foregroundStyle(Color.brandGreen.opacity(0.85))
            }
        }
        .saturation(defeated ? 0.3 : 1)
        .onAppear { breathe = true }
    }
}

struct RaidStat: View {
    let icon: String
    let tint: Color
    let label: String
    let value: String

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .font(.caption)
                .foregroundStyle(tint)
                .frame(width: 22, height: 22)
                .background(tint.opacity(0.12))
                .clipShape(Circle())
            VStack(alignment: .leading, spacing: 1) {
                Text(value).font(.callout.weight(.semibold).monospacedDigit())
                Text(label).font(.caption2).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Live countdown to the weekly reset (Monday 00:00 UTC).
struct RaidCountdown: View {
    let endsAt: Int
    let defeated: Bool

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let remaining = max(0, endsAt - Int(context.date.timeIntervalSince1970))
            VStack(alignment: .trailing, spacing: 2) {
                Image(systemName: "hourglass")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(RaidFormat.countdown(remaining))
                    .font(.caption.weight(.semibold).monospacedDigit())
                Text(defeated ? "next boss" : "left")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

/// "You dealt N damage" — shown over the raid card after a sync lands a hit.
struct RaidDamageToast: View {
    let hit: RaidHit

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: hit.justDefeated ? "trophy.fill" : "bolt.fill")
                .foregroundStyle(hit.justDefeated ? Color.brandYellow : Color.brandOrange)
            VStack(alignment: .leading, spacing: 1) {
                Text(hit.justDefeated
                     ? "\(hit.bossName) is down!"
                     : "\(RaidFormat.number(hit.damage)) damage to \(hit.bossName)")
                    .font(.callout.weight(.semibold))
                    .lineLimit(1)
                if hit.justDefeated {
                    Text("+\(hit.rewardXP) XP for every contributor")
                        .font(.caption).foregroundStyle(.secondary)
                    if let title = hit.rewardTitle, !title.isEmpty {
                        Text("Title unlocked: \(title)")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(Color.brandYellow)
                    }
                    if let aura = hit.rewardCosmetic, !aura.isEmpty {
                        Text("\(aura.auraDisplayName) unlocked. Equip it in Account.")
                            .font(.caption)
                            .foregroundStyle(aura.auraColor)
                    }
                } else if hit.defeated {
                    Text("Boss already defeated — still counted")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
        .background(.regularMaterial)
        .clipShape(Capsule())
        .shadow(color: .black.opacity(0.18), radius: 8, y: 3)
    }
}

// MARK: - Helpers

enum RaidFormat {
    static func number(_ value: Int) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.maximumFractionDigits = 0
        return formatter.string(from: NSNumber(value: value)) ?? "\(value)"
    }

    static func countdown(_ seconds: Int) -> String {
        let days = seconds / 86_400
        let hours = (seconds % 86_400) / 3_600
        let minutes = (seconds % 3_600) / 60
        let secs = seconds % 60
        if days > 0 { return "\(days)d \(hours)h" }
        if hours > 0 { return "\(hours)h \(minutes)m" }
        return String(format: "%d:%02d", minutes, secs)
    }
}

extension Color {
    /// "#RRGGBB" or "RRGGBB" → Color; nil for anything else.
    init?(raidHex: String) {
        var hex = raidHex.trimmingCharacters(in: .whitespacesAndNewlines)
        if hex.hasPrefix("#") { hex.removeFirst() }
        guard hex.count == 6, let value = UInt32(hex, radix: 16) else { return nil }
        self.init(
            red: Double((value >> 16) & 0xFF) / 255,
            green: Double((value >> 8) & 0xFF) / 255,
            blue: Double(value & 0xFF) / 255
        )
    }
}
