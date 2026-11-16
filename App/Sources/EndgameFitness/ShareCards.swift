//
//  ShareCards.swift
//  Endgame Fitness
//
//  Copyright (c) 2026 Daniel Bates / Bates LLC. All rights reserved.
//
//  Rendered share images (session summary, level up, PR, raid kill, player
//  card) handed to the system share sheet via ShareLink. Facebook, Instagram,
//  Messages, etc. appear there when installed; no third-party SDK is linked
//  (Docs/SOCIAL_DESIGN.md explains why).
//

import SwiftUI

enum ShareCardKind: Identifiable, Equatable {
    case session(volume: Double, reps: Int, minutes: Int, xp: Int)
    case levelUp(level: Int, title: String?)
    case pr(exercise: String, e1rm: Double)
    case raidKill(boss: String, symbol: String, damage: Int)
    case playerCard

    var id: String {
        switch self {
        case .session:    return "session"
        case .levelUp:    return "level"
        case .pr:         return "pr"
        case .raidKill:   return "raid"
        case .playerCard: return "card"
        }
    }

    var label: String {
        switch self {
        case .session:    return "Last session"
        case .levelUp:    return "Level"
        case .pr:         return "Top PR"
        case .raidKill:   return "Raid kill"
        case .playerCard: return "Player card"
        }
    }

    var caption: String {
        switch self {
        case .session(let v, _, _, let xp): return "Just moved \(Int(v).formatted()) lb and earned \(xp) XP in Endgame Fitness."
        case .levelUp(let l, _):            return "Hit level \(l) in Endgame Fitness."
        case .pr(let ex, let w):            return "New \(ex.capitalized) PR: \(Int(w)) lb estimated 1RM."
        case .raidKill(let b, _, _):        return "We took down \(b) in Endgame Fitness."
        case .playerCard:                   return "Add me as a rival in Endgame Fitness."
        }
    }
}

struct SocialShareCardView: View {
    let kind: ShareCardKind
    let card: PlayerCard

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 10) {
                Image(systemName: card.symbol)
                    .font(.system(size: 22, weight: .bold))
                    .frame(width: 44, height: 44)
                    .background(card.color, in: Circle())
                VStack(alignment: .leading, spacing: 2) {
                    Text(card.name).font(.system(size: 20, weight: .bold))
                    Text("Level \(card.level)\(card.heroClass.map { " · \($0.capitalized)" } ?? "")")
                        .font(.system(size: 14, weight: .medium)).opacity(0.8)
                }
                Spacer()
            }
            Spacer(minLength: 0)
            headline
            Spacer(minLength: 0)
            HStack {
                Label("\(card.streak)-day streak", systemImage: "flame.fill")
                Spacer()
                Text("ENDGAME FITNESS").font(.system(size: 12, weight: .heavy)).tracking(2)
            }
            .font(.system(size: 13, weight: .semibold))
            .opacity(0.85)
        }
        .foregroundStyle(.white)
        .padding(28)
        .frame(width: 540, height: 540)
        .background(
            LinearGradient(colors: [Color.brandPurple, Color.brandBlue.opacity(0.9), Color.black.opacity(0.85)],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
        )
    }

    @ViewBuilder
    private var headline: some View {
        switch kind {
        case .session(let volume, let reps, let minutes, let xp):
            big("SESSION COMPLETE", "\(Int(volume).formatted()) lb", "\(reps) reps · \(minutes) min · +\(xp) XP")
        case .levelUp(let level, let title):
            big("LEVEL UP", "Level \(level)", title ?? "The grind pays.")
        case .pr(let exercise, let e1rm):
            big("PERSONAL RECORD", "\(Int(e1rm)) lb", "\(exercise.capitalized) · estimated 1RM")
        case .raidKill(let boss, let symbol, let damage):
            VStack(alignment: .leading, spacing: 8) {
                Image(systemName: symbol).font(.system(size: 54, weight: .bold))
                big("RAID BOSS DEFEATED", boss, "\(damage.formatted()) damage dealt")
            }
        case .playerCard:
            HStack(alignment: .center, spacing: 18) {
                if let qr = PlayerCardCode.qrImage(PlayerCardCode.deepLink(card).absoluteString, scale: 5) {
                    Image(decorative: qr, scale: 1).interpolation(.none).resizable()
                        .frame(width: 190, height: 190).padding(8).background(.white, in: RoundedRectangle(cornerRadius: 12))
                }
                VStack(alignment: .leading, spacing: 6) {
                    Text("RIVAL ME").font(.system(size: 14, weight: .heavy)).tracking(2)
                    Text("\(Int(card.currentWeeklyVolume).formatted()) lb").font(.system(size: 34, weight: .black))
                    Text("this week").font(.system(size: 14))
                    if let pr = card.prs.first { Text("\(pr.exercise.capitalized) \(Int(pr.e1rm))").font(.system(size: 15, weight: .semibold)) }
                }
            }
        }
    }

    private func big(_ eyebrow: String, _ main: String, _ sub: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(eyebrow).font(.system(size: 14, weight: .heavy)).tracking(2).opacity(0.85)
            Text(main).font(.system(size: 54, weight: .black)).minimumScaleFactor(0.4).lineLimit(2)
            Text(sub).font(.system(size: 17, weight: .medium)).opacity(0.9)
        }
    }
}

@MainActor
enum ShareCardRenderer {
    static func image(_ kind: ShareCardKind, card: PlayerCard) -> Image? {
        let renderer = ImageRenderer(content: SocialShareCardView(kind: kind, card: card))
        renderer.scale = 2
        guard let cg = renderer.cgImage else { return nil }
        return Image(decorative: cg, scale: 2)
    }

    /// What can be shared right now for the current player.
    static func options(card: PlayerCard) -> [ShareCardKind] {
        var out: [ShareCardKind] = [.playerCard, .levelUp(level: card.level, title: card.title)]
        let game = GameProfileService.shared
        if let id = LocalPlayerStore.shared.currentID,
           let last = game.engine.store.state(id).sessions.values.filter(\.counted).max(by: { $0.performedAt < $1.performedAt }) {
            out.insert(.session(volume: last.volume, reps: last.reps, minutes: last.durationSecs / 60, xp: last.xp), at: 0)
        }
        if let pr = card.prs.first { out.append(.pr(exercise: pr.exercise, e1rm: pr.e1rm)) }
        if let raid = game.raid, raid.defeated {
            out.append(.raidKill(boss: raid.boss.name, symbol: raid.boss.symbol, damage: raid.myDamage))
        } else if let party = GymParty.shared.boss, party.defeatedAt != nil {
            out.append(.raidKill(boss: party.name, symbol: party.symbol, damage: party.damage))
        }
        return out
    }
}

/// A share button for one card: preview + system share sheet.
struct ShareCardButton: View {
    let kind: ShareCardKind
    let card: PlayerCard

    var body: some View {
        if let image = ShareCardRenderer.image(kind, card: card) {
            ShareLink(item: image, subject: Text("Endgame Fitness"), message: Text(kind.caption),
                      preview: SharePreview(kind.label, image: image)) {
                VStack(spacing: 6) {
                    image.resizable().scaledToFit().frame(width: 120, height: 120)
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                    Label(kind.label, systemImage: "square.and.arrow.up").font(.caption.weight(.semibold))
                }
            }
            .buttonStyle(.plain)
        }
    }
}
