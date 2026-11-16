//
//  RootView.swift
//  Endgame Fitness
//
//  Decides what the user sees at launch, in this order:
//    1. no local player chosen                 -> PlayerPickerView
//    2. this player hasn't onboarded yet       -> OnboardingView
//    3. otherwise                              -> the app
//
//  There is no account and no network: players are local to the device
//  (LocalPlayers.swift) and the game runs on the device (LocalGame.swift).
//

import SwiftUI

struct RootView: View {
    /// Device-wide flag owned by the app scene. Kept for the training log.
    @Binding var hasCompletedOnboarding: Bool

    @EnvironmentObject var workoutManager: WorkoutManager
    @StateObject private var players = LocalPlayerStore.shared
    @StateObject private var game = GameProfileService.shared
    @Environment(\.scenePhase) private var scenePhase

    @State private var celebratingLevel: Int?
    @State private var onboardedAccounts = AccountFlags(key: "ef.onboardedAccounts")

    private enum Stage: Equatable {
        case picker, onboarding, app
    }

    var body: some View {
        content
            .frame(
                minWidth: Platform.isDesktop ? 900 : nil,
                minHeight: Platform.isDesktop ? 700 : nil
            )
            .task { launch() }
            .onChange(of: game.profile?.isOnboarded) { _, onboarded in
                if onboarded == true, let id = players.currentID { onboardedAccounts.insert(id) }
            }
            .onChange(of: scenePhase) { _, phase in
                guard phase == .active, players.current != nil else { return }
                Task { await game.sync() }
            }
            // A workout can report more than one level gained at once; show the
            // level actually reached rather than a burst of overlays.
            .onChange(of: game.pendingLevelUps) { _, count in
                guard count > 0, let level = game.profile?.level else { return }
                celebratingLevel = level
                game.pendingLevelUps = 0
            }
            .overlay { RewardToastOverlay() }
            .overlay {
                if let level = celebratingLevel {
                    LevelUpOverlay(level: level, hasPointToSpend: hasTalentToSpend) {
                        celebratingLevel = nil
                    }
                    .transition(.opacity)
                }
            }
            .animation(.easeInOut(duration: 0.25), value: celebratingLevel)
    }

    /// Points are only worth announcing while the tree has room for them.
    private var hasTalentToSpend: Bool {
        guard (game.profile?.talentPoints ?? 0) > 0 else { return false }
        return (game.talents?.remainingCapacity ?? 1) > 0
    }

    // MARK: Gate

    private var stage: Stage {
        guard let id = players.currentID else { return .picker }
        if onboardedAccounts.contains(id) || game.profile?.isOnboarded == true { return .app }
        return .onboarding
    }

    @ViewBuilder
    private var content: some View {
        switch stage {
        case .picker:
            PlayerPickerView()
        case .onboarding:
            OnboardingView(hasCompletedOnboarding: onboardingBinding)
                .environmentObject(workoutManager)
        case .app:
            ContentView()
                .environmentObject(workoutManager)
        }
    }

    /// OnboardingView reports completion by setting its binding to true.
    private var onboardingBinding: Binding<Bool> {
        Binding(
            get: { false },
            set: { done in
                guard done else { return }
                hasCompletedOnboarding = true
                guard let id = players.currentID else { return }
                onboardedAccounts.insert(id)
                saveOnboardingAnswers()
            }
        )
    }

    // MARK: Launch

    private func launch() {
        #if DEBUG
        // `-ef.skipOnboarding` and `-ef.tab <n>` jump straight to a tab so
        // every screen can be screenshotted without taps. `-ef.player <name>`
        // picks (or creates) a local player.
        if let i = CommandLine.arguments.firstIndex(of: "-ef.player"), CommandLine.arguments.count > i + 1 {
            let name = CommandLine.arguments[i + 1]
            let player = players.players.first { $0.name == name }
                ?? players.create(name: name, symbol: LocalPlayer.symbols[0], colorIndex: 0, pin: nil)
            players.select(player.id)
        }
        if CommandLine.arguments.contains("-ef.skipOnboarding") {
            hasCompletedOnboarding = true
            if let id = players.currentID { onboardedAccounts.insert(id) }
        }
        if let i = CommandLine.arguments.firstIndex(of: "-ef.tab"), CommandLine.arguments.count > i + 1,
           let tab = Int(CommandLine.arguments[i + 1]) {
            workoutManager.selectedTab = tab
        }
        #endif
        // Installs from before local players: the device was already onboarded,
        // so the player who adopts its history doesn't need to be asked again.
        if hasCompletedOnboarding, onboardedAccounts.isEmpty, players.players.count == 1, let id = players.currentID {
            onboardedAccounts.insert(id)
        }
    }

    /// Onboarding answers go on the local player's profile.
    private func saveOnboardingAnswers() {
        var fields: [String: Any] = ["onboarded": true]
        if let profile = workoutManager.userProfile {
            if let goal = profile.primaryGoals.first { fields["training_goal"] = goal.rawValue }
            fields["experience_level"] = profile.experienceLevel.rawValue
            fields["equipment_level"] = profile.availableEquipment.rawValue
            if profile.weight > 0 { fields["body_weight"] = profile.weight }
            if profile.height > 0 { fields["height_inches"] = profile.height }
        }
        game.applyProfileFields(fields)
    }
}

/// A set of account ids persisted in UserDefaults (per-account flags that are
/// not secrets: "onboarded on this device", "profile setup shown").
struct AccountFlags {
    let key: String
    private(set) var ids: Set<String>

    init(key: String) {
        self.key = key
        self.ids = Set(UserDefaults.standard.stringArray(forKey: key) ?? [])
    }

    var isEmpty: Bool { ids.isEmpty }

    func contains(_ id: String) -> Bool { ids.contains(id) }

    mutating func insert(_ id: String) {
        guard ids.insert(id).inserted else { return }
        UserDefaults.standard.set(Array(ids), forKey: key)
    }

    mutating func remove(_ id: String) {
        guard ids.remove(id) != nil else { return }
        UserDefaults.standard.set(Array(ids), forKey: key)
    }
}

struct SplashView: View {
    var message: String?

    @State private var pulse = false

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "figure.strengthtraining.traditional")
                .font(.system(size: 56))
                .foregroundStyle(Color.brandPurple)
                .scaleEffect(pulse ? 1.06 : 0.94)
                .animation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true), value: pulse)
            Text("Endgame Fitness")
                .font(.title2.weight(.semibold))
            SwiftUI.ProgressView()
                .controlSize(.small)
            if let message {
                Text(message)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.platformWindowBackground.ignoresSafeArea())
        .onAppear { pulse = true }
    }
}
