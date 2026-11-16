//
//  CelebrationViews.swift
//  Endgame Fitness
//
//  Copyright (c) 2026 Daniel Bates / Bates LLC. All rights reserved.
//  https://github.com/danielalanbates/endgame-fitness
//
//  Small toasts for rewards the server confirmed after a sync: the real XP a
//  workout earned (the in-session number is only an estimate) and any
//  achievements it unlocked. Level-ups keep their full-screen overlay.
//

import SwiftUI

enum RewardToast: Identifiable, Equatable {
    case xp(XPGainEvent)
    case achievement(AchievementUnlock)

    var id: String {
        switch self {
        case .xp(let event):          return "xp-\(event.id)"
        case .achievement(let unlock): return "ach-\(unlock.id)"
        }
    }
}

/// Watches the game service and shows one reward toast at a time.
struct RewardToastOverlay: View {
    @ObservedObject var game = GameProfileService.shared

    @State private var current: RewardToast?
    @State private var queue: [RewardToast] = []
    @State private var timer: Task<Void, Never>?

    var body: some View {
        VStack {
            if let current {
                RewardToastView(toast: current)
                    .onTapGesture { advance() }
                    .transition(.move(edge: .top).combined(with: .opacity))
                    .padding(.top, 8)
            }
            Spacer()
        }
        .frame(maxWidth: .infinity)
        .animation(.spring(response: 0.45, dampingFraction: 0.8), value: current)
        .allowsHitTesting(current != nil)
        .onChange(of: game.xpEvent) { _, event in
            guard let event else { return }
            enqueue([.xp(event)])
            game.xpEvent = nil
        }
        .onChange(of: game.pendingAchievements) { _, ids in
            guard !ids.isEmpty else { return }
            enqueue(game.unlockDetails(for: ids).map { .achievement($0) })
            game.pendingAchievements = []
        }
    }

    private func enqueue(_ toasts: [RewardToast]) {
        queue += toasts
        if current == nil { advance() }
    }

    private func advance() {
        timer?.cancel()
        guard !queue.isEmpty else {
            current = nil
            return
        }
        let next = queue.removeFirst()
        current = next
        if case .achievement = next { Platform.success() }
        timer = Task {
            try? await Task.sleep(nanoseconds: 3_200_000_000)
            if !Task.isCancelled { advance() }
        }
    }
}

struct RewardToastView: View {
    let toast: RewardToast

    var body: some View {
        HStack(spacing: 12) {
            icon
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.callout.weight(.semibold)).lineLimit(1)
                Text(subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
        .background(.regularMaterial)
        .clipShape(Capsule())
        .shadow(color: .black.opacity(0.18), radius: 8, y: 3)
        .padding(.horizontal, 16)
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private var icon: some View {
        switch toast {
        case .xp:
            Image(systemName: "star.fill")
                .foregroundStyle(Color.brandYellow)
                .font(.title3)
        case .achievement(let unlock):
            Image(systemName: unlock.icon)
                .foregroundStyle(.white)
                .frame(width: 30, height: 30)
                .background(Circle().fill(unlock.rarityColor))
        }
    }

    private var title: String {
        switch toast {
        case .xp(let event):           return "+\(event.xp) XP"
        case .achievement:             return "Achievement unlocked"
        }
    }

    private var subtitle: String {
        switch toast {
        case .xp(let event):
            return event.workouts == 1 ? "Confirmed for your workout" : "Confirmed for \(event.workouts) workouts"
        case .achievement(let unlock):
            return unlock.title
        }
    }
}
