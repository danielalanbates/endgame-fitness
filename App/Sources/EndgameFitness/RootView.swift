//
//  RootView.swift
//  Endgame Fitness
//
//  Decides what the user sees at launch, in this order:
//    1. restoring a stored session   -> splash
//    2. not signed in                -> SignInView
//    3. signed in, no onboarding yet -> OnboardingView
//    4. otherwise                    -> the app
//
//  Sign-in comes before onboarding on purpose: the onboarding answers (goal,
//  experience, equipment, bodyweight) belong on the server profile, so we need
//  to know who the person is before asking them.
//

import SwiftUI

struct RootView: View {
    @Binding var hasCompletedOnboarding: Bool

    @EnvironmentObject var workoutManager: WorkoutManager
    @StateObject private var auth = BatesAIAuth.shared
    @StateObject private var game = GameProfileService.shared

    @State private var celebratingLevel: Int?

    var body: some View {
        content
            .frame(
                minWidth: Platform.isDesktop ? 900 : nil,
                minHeight: Platform.isDesktop ? 700 : nil
            )
            .task {
                await auth.restoreSession()
                #if DEBUG
                // Headless UI verification (simulator): `-ef.autologin email password`
                // signs in a test account without touching the keyboard.
                if !auth.isSignedIn, let i = CommandLine.arguments.firstIndex(of: "-ef.autologin"),
                   CommandLine.arguments.count > i + 2 {
                    await auth.signIn(email: CommandLine.arguments[i + 1], password: CommandLine.arguments[i + 2])
                }
                // `-ef.skipOnboarding` and `-ef.tab <n>` jump straight to a tab so
                // every screen can be screenshotted with `simctl io` (no taps).
                if CommandLine.arguments.contains("-ef.skipOnboarding") { hasCompletedOnboarding = true }
                if let i = CommandLine.arguments.firstIndex(of: "-ef.tab"), CommandLine.arguments.count > i + 1,
                   let tab = Int(CommandLine.arguments[i + 1]) {
                    workoutManager.selectedTab = tab
                }
                #endif
                if auth.isSignedIn { await game.loadAll() }
            }
            .onChange(of: auth.isSignedIn) { _, signedIn in
                Task {
                    if signedIn {
                        await game.loadAll()
                    } else {
                        game.reset()
                    }
                }
            }
            // A sync can report more than one level gained at once; show the
            // level actually reached rather than a burst of overlays.
            .onChange(of: game.pendingLevelUps) { _, count in
                guard count > 0, let level = game.profile?.level else { return }
                celebratingLevel = level
                game.pendingLevelUps = 0
            }
            .overlay {
                if let level = celebratingLevel {
                    LevelUpOverlay(level: level) { celebratingLevel = nil }
                        .transition(.opacity)
                }
            }
            .animation(.easeInOut(duration: 0.25), value: celebratingLevel)
    }

    @ViewBuilder
    private var content: some View {
        if auth.isRestoring {
            SplashView()
        } else if !auth.isSignedIn {
            SignInView()
        } else if !hasCompletedOnboarding {
            OnboardingView(hasCompletedOnboarding: $hasCompletedOnboarding)
                .environmentObject(workoutManager)
                .onDisappear {
                    // Push the onboarding answers up to the server profile so a
                    // second device doesn't have to ask again.
                    Task { await syncOnboardingAnswers() }
                }
        } else {
            ContentView()
                .environmentObject(workoutManager)
        }
    }

    private func syncOnboardingAnswers() async {
        var fields: [String: Any] = [:]
        if let profile = workoutManager.userProfile {
            // The onboarding flow collects several goals; the server profile
            // stores the primary one for programming decisions.
            if let goal = profile.primaryGoals.first {
                fields["training_goal"] = goal.rawValue
            }
            fields["experience_level"] = profile.experienceLevel.rawValue
            fields["equipment_level"] = profile.availableEquipment.rawValue
            if profile.weight > 0 { fields["body_weight"] = profile.weight }
            if profile.height > 0 { fields["height_inches"] = profile.height }
            if !profile.name.isEmpty { fields["display_name"] = profile.name }
        }
        guard !fields.isEmpty else { return }
        await game.updateProfile(fields)
    }
}

struct SplashView: View {
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
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.platformWindowBackground.ignoresSafeArea())
        .onAppear { pulse = true }
    }
}
