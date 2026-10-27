//
//  RootView.swift
//  Endgame Fitness
//
//  Decides what the user sees at launch, in this order:
//    1. restoring a stored session              -> splash
//    2. not signed in                           -> SignInView
//    3. signed in, account not onboarded yet    -> wait for the server profile,
//                                                  then OnboardingView only if
//                                                  the server has no answers
//    4. first time this account is on a device  -> ProfileSetupView (once)
//    5. otherwise                               -> the app
//
//  Sign-in comes before onboarding on purpose: the onboarding answers (goal,
//  experience, equipment, bodyweight) belong on the server profile, so we need
//  to know who the person is before asking them — and a returning member on a
//  new device should not be asked again (API_V2 §2.1 `onboarded`).
//

import SwiftUI

struct RootView: View {
    /// Device-wide flag owned by the app scene. Kept for the training log and
    /// for migrating installs from before onboarding was tracked per account.
    @Binding var hasCompletedOnboarding: Bool

    @EnvironmentObject var workoutManager: WorkoutManager
    @StateObject private var auth = BatesAIAuth.shared
    @StateObject private var game = GameProfileService.shared
    @Environment(\.scenePhase) private var scenePhase

    @State private var celebratingLevel: Int?
    @State private var onboardedAccounts = AccountFlags(key: "ef.onboardedAccounts")
    @State private var setupDoneAccounts = AccountFlags(key: "ef.profileSetupAccounts")
    /// Onboarding finished but the answers have not reached the server yet.
    @State private var answersPending = AccountFlags(key: "ef.onboardingAnswersPending")
    @State private var justOnboarded = false
    @State private var continueOffline = false

    private enum Stage: Equatable {
        case splash, signIn, loadingProfile, offline, onboarding, profileSetup, app
    }

    var body: some View {
        content
            .frame(
                minWidth: Platform.isDesktop ? 900 : nil,
                minHeight: Platform.isDesktop ? 700 : nil
            )
            .task { await launch() }
            .onChange(of: auth.user?.id) { _, userID in
                continueOffline = false
                justOnboarded = false
                if userID != nil {
                    Task { await game.loadAll() }
                } else {
                    game.reset()
                }
            }
            .onChange(of: game.profileState) { _, state in
                // Onboarded offline: deliver the answers once the server answers.
                guard state == .loaded, let userID = auth.user?.id, answersPending.contains(userID) else { return }
                Task { await deliverOnboardingAnswers(for: userID) }
            }
            .onChange(of: game.profile?.isOnboarded) { _, onboarded in
                // The server has this member's answers: never ask again here.
                if onboarded == true, let profile = game.profile, profile.userID == auth.user?.id {
                    onboardedAccounts.insert(profile.userID)
                }
            }
            .onChange(of: scenePhase) { _, phase in
                guard phase == .active else { return }
                Task {
                    await auth.revalidateIfNeeded()
                    if auth.isSignedIn { await game.sync() }
                }
            }
            // A sync can report more than one level gained at once; show the
            // level actually reached rather than a burst of overlays.
            .onChange(of: game.pendingLevelUps) { _, count in
                guard count > 0, let level = game.profile?.level else { return }
                celebratingLevel = level
                game.pendingLevelUps = 0
            }
            .overlay { RewardToastOverlay() }
            .overlay {
                if let level = celebratingLevel {
                    LevelUpOverlay(level: level, hasPointToSpend: (game.profile?.talentPoints ?? 0) > 0) {
                        celebratingLevel = nil
                    }
                    .transition(.opacity)
                }
            }
            .animation(.easeInOut(duration: 0.25), value: celebratingLevel)
    }

    // MARK: Gate

    private var stage: Stage {
        if auth.isRestoring { return .splash }
        guard let userID = auth.user?.id else { return .signIn }

        let serverProfile = game.profile?.userID == userID ? game.profile : nil
        if onboardedAccounts.contains(userID) || serverProfile?.isOnboarded == true {
            return needsProfileSetup(userID, profile: serverProfile) ? .profileSetup : .app
        }
        if serverProfile != nil || continueOffline { return .onboarding }
        switch game.profileState {
        case .failed:
            return .offline
        case .idle, .loading, .loaded:
            return .loadingProfile
        }
    }

    /// Hero name + privacy, once per account per device: right after
    /// onboarding, or when the profile still looks untouched (private, no bio).
    private func needsProfileSetup(_ userID: String, profile: FitnessProfile?) -> Bool {
        guard !setupDoneAccounts.contains(userID), let profile else { return false }
        return justOnboarded || (!profile.isPublic && (profile.bio ?? "").isEmpty)
    }

    @ViewBuilder
    private var content: some View {
        switch stage {
        case .splash:
            SplashView()
        case .signIn:
            SignInView()
        case .loadingProfile:
            SplashView(message: "Loading your profile…")
        case .offline:
            OfflineProfileView(
                message: offlineMessage,
                onRetry: { Task { await game.loadProfile() } },
                onContinue: { continueOffline = true }
            )
        case .onboarding:
            OnboardingView(hasCompletedOnboarding: onboardingBinding)
                .environmentObject(workoutManager)
        case .profileSetup:
            ProfileSetupView {
                if let userID = auth.user?.id { setupDoneAccounts.insert(userID) }
                justOnboarded = false
            }
            .environmentObject(workoutManager)
        case .app:
            ContentView()
                .environmentObject(workoutManager)
        }
    }

    private var offlineMessage: String {
        if case .failed(let message) = game.profileState { return message }
        return "Can't reach batesai.org."
    }

    /// OnboardingView reports completion by setting its binding to true. The
    /// device flag may already be true (another member onboarded here), so
    /// completion is caught in the setter rather than by observing the flag.
    private var onboardingBinding: Binding<Bool> {
        Binding(
            get: { false },
            set: { done in
                guard done else { return }
                hasCompletedOnboarding = true
                guard let userID = auth.user?.id else { return }
                onboardedAccounts.insert(userID)
                justOnboarded = true
                answersPending.insert(userID)
                Task { await deliverOnboardingAnswers(for: userID) }
            }
        )
    }

    // MARK: Launch

    private func launch() async {
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
        if CommandLine.arguments.contains("-ef.skipOnboarding") {
            hasCompletedOnboarding = true
            if let userID = auth.user?.id {
                onboardedAccounts.insert(userID)
                setupDoneAccounts.insert(userID)
            }
        }
        if let i = CommandLine.arguments.firstIndex(of: "-ef.tab"), CommandLine.arguments.count > i + 1,
           let tab = Int(CommandLine.arguments[i + 1]) {
            workoutManager.selectedTab = tab
        }
        #endif
        // Installs from before per-account onboarding: whoever's session is
        // being restored is the person who onboarded this device.
        if hasCompletedOnboarding, onboardedAccounts.isEmpty, let userID = auth.user?.id {
            onboardedAccounts.insert(userID)
            setupDoneAccounts.insert(userID)
            answersPending.insert(userID)
            await deliverOnboardingAnswers(for: userID)
        }
    }

    private func deliverOnboardingAnswers(for userID: String) async {
        guard auth.user?.id == userID else { return }
        if await syncOnboardingAnswers() { answersPending.remove(userID) }
    }

    /// Push the onboarding answers up to the server profile so a second device
    /// doesn't have to ask again. Returns true once the server has them.
    private func syncOnboardingAnswers() async -> Bool {
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
            // The hero name chosen in ProfileSetupView wins over the onboarding name.
            let setupDone = auth.user.map { setupDoneAccounts.contains($0.id) } ?? false
            if !setupDone, ProfileRules.displayNameProblem(profile.name) == nil {
                fields["display_name"] = profile.name.trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        fields["tz_offset_min"] = TimeZone.current.secondsFromGMT() / 60
        return await game.saveProfile(fields) == nil
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

/// Signed in, but the profile could not be fetched and this account has not
/// onboarded on this device yet.
struct OfflineProfileView: View {
    let message: String
    let onRetry: () -> Void
    let onContinue: () -> Void

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "wifi.exclamationmark")
                .font(.system(size: 48))
                .foregroundStyle(.secondary)
            Text("Couldn't load your profile")
                .font(.title2.bold())
            Text(message)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Text("If you've used Endgame Fitness before, try again once you're online so your setup comes with you. Or set up on this device now; your answers are saved to your profile when you're back online.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 420)
            HStack(spacing: 12) {
                Button("Set up on this device", action: onContinue)
                    .buttonStyle(.bordered)
                Button("Try again", action: onRetry)
                    .buttonStyle(.borderedProminent)
                    .tint(.brandPurple)
            }
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.platformWindowBackground.ignoresSafeArea())
    }
}
