//
//  AvatarViews.swift
//  SwiftUI views for 3D blob avatar system
//

import SwiftUI
import SceneKit

// MARK: - Avatar Questionnaire View
struct AvatarQuestionnaireView: View {
    @Binding var profile: AvatarBodyProfile
    @Binding var isComplete: Bool

    @State private var currentStep = 0
    @State private var showPreview = false

    var body: some View {
        VStack(spacing: 20) {
            // Header
            Text("Create Your Avatar")
                .font(.system(size: 32, weight: .bold))

            Text("Make your avatar roughly similar to yourself to get started!")
                .font(.system(size: 16))
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal)

            // Progress indicator
            HStack(spacing: 8) {
                ForEach(0..<3) { step in
                    Circle()
                        .fill(step <= currentStep ? Color.blue : Color.gray.opacity(0.3))
                        .frame(width: 12, height: 12)
                }
            }
            .padding(.bottom)

            Spacer()

            // Question content
            Group {
                switch currentStep {
                case 0:
                    heightQuestionView
                case 1:
                    bodyTypeQuestionView
                case 2:
                    bellyQuestionView
                default:
                    EmptyView()
                }
            }
            .frame(maxWidth: 500)

            Spacer()

            // Navigation buttons
            HStack(spacing: 20) {
                if currentStep > 0 {
                    Button("Back") {
                        withAnimation {
                            currentStep -= 1
                        }
                    }
                    .buttonStyle(.bordered)
                }

                Spacer()

                if currentStep < 2 {
                    Button("Next") {
                        withAnimation {
                            currentStep += 1
                        }
                    }
                    .buttonStyle(.borderedProminent)
                } else {
                    Button("See My Avatar!") {
                        withAnimation {
                            showPreview = true
                        }
                    }
                    .buttonStyle(.borderedProminent)
                }
            }
            .padding(.horizontal, Platform.isDesktop ? 40 : 16)
            .padding(.bottom, 20)
        }
        .padding()
        .desktopSheetFrame(width: 700, height: 650)
        .sheet(isPresented: $showPreview) {
            AvatarPreviewView(profile: $profile, isComplete: $isComplete)
        }
    }

    // MARK: - Question Views

    private var heightQuestionView: some View {
        VStack(spacing: 20) {
            Text("How tall are you?")
                .font(.system(size: 24, weight: .semibold))

            VStack(spacing: 12) {
                ForEach(AvatarBodyProfile.Height.allCases, id: \.self) { height in
                    Button(action: {
                        profile.height = height
                    }) {
                        HStack {
                            Image(systemName: profile.height == height ? "checkmark.circle.fill" : "circle")
                                .foregroundColor(.blue)
                            Text(height.rawValue)
                                .foregroundColor(.primary)
                            Spacer()
                            Text(heightDescription(height))
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                        .padding()
                        .background(
                            RoundedRectangle(cornerRadius: 10)
                                .fill(profile.height == height ? Color.blue.opacity(0.1) : Color.clear)
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 10)
                                .stroke(profile.height == height ? Color.blue : Color.gray.opacity(0.3), lineWidth: 2)
                        )
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private var bodyTypeQuestionView: some View {
        VStack(spacing: 20) {
            Text("What's your current build?")
                .font(.system(size: 24, weight: .semibold))

            Text("Don't worry - this is just a starting point! Your avatar will transform as you progress.")
                .font(.caption)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)

            VStack(spacing: 12) {
                ForEach(AvatarBodyProfile.BodyType.allCases, id: \.self) { bodyType in
                    Button(action: {
                        profile.bodyType = bodyType
                    }) {
                        HStack {
                            Image(systemName: profile.bodyType == bodyType ? "checkmark.circle.fill" : "circle")
                                .foregroundColor(.blue)
                            Text(bodyType.rawValue)
                                .foregroundColor(.primary)
                            Spacer()
                            Text(bodyTypeDescription(bodyType))
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                        .padding()
                        .background(
                            RoundedRectangle(cornerRadius: 10)
                                .fill(profile.bodyType == bodyType ? Color.blue.opacity(0.1) : Color.clear)
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 10)
                                .stroke(profile.bodyType == bodyType ? Color.blue : Color.gray.opacity(0.3), lineWidth: 2)
                        )
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private var bellyQuestionView: some View {
        VStack(spacing: 20) {
            Text("Belly profile?")
                .font(.system(size: 24, weight: .semibold))

            Text("No judgment - we're all on our own journey! 💪")
                .font(.caption)
                .foregroundColor(.secondary)

            VStack(spacing: 12) {
                ForEach(AvatarBodyProfile.BellySize.allCases, id: \.self) { bellySize in
                    Button(action: {
                        profile.bellySize = bellySize
                    }) {
                        HStack {
                            Image(systemName: profile.bellySize == bellySize ? "checkmark.circle.fill" : "circle")
                                .foregroundColor(.blue)
                            Text(bellySize.rawValue)
                                .foregroundColor(.primary)
                            Spacer()
                        }
                        .padding()
                        .background(
                            RoundedRectangle(cornerRadius: 10)
                                .fill(profile.bellySize == bellySize ? Color.blue.opacity(0.1) : Color.clear)
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 10)
                                .stroke(profile.bellySize == bellySize ? Color.blue : Color.gray.opacity(0.3), lineWidth: 2)
                        )
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    // MARK: - Helper Functions

    private func heightDescription(_ height: AvatarBodyProfile.Height) -> String {
        switch height {
        case .short: return "Under 5'7\""
        case .average: return "5'7\" - 6'0\""
        case .tall: return "Over 6'0\""
        }
    }

    private func bodyTypeDescription(_ bodyType: AvatarBodyProfile.BodyType) -> String {
        switch bodyType {
        case .slim: return "Lean and light"
        case .average: return "Medium build"
        case .athletic: return "Muscular build"
        case .heavy: return "Larger build"
        }
    }
}

// MARK: - Avatar Preview View
struct AvatarPreviewView: View {
    @Binding var profile: AvatarBodyProfile
    @Binding var isComplete: Bool

    @State private var blobAvatar: BlobAvatar3D?
    @Environment(\.dismiss) var dismiss

    var body: some View {
        VStack(spacing: 20) {
            Text("Meet Your Avatar!")
                .font(.system(size: 32, weight: .bold))

            Text("This is your starting point. Watch it transform as you get stronger!")
                .font(.system(size: 14))
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)

            // 3D Avatar Display
            if let avatar = blobAvatar {
                SceneView(
                    scene: avatar.getScene(),
                    options: [.allowsCameraControl, .autoenablesDefaultLighting]
                )
                .frame(height: 400)
                .background(Color.black.opacity(0.05))
                .cornerRadius(12)
                .onAppear {
                    avatar.startIdleAnimation()
                }
            }

            // Fun fact about the blob
            VStack(spacing: 8) {
                Text("🎮 Pro Tip")
                    .font(.headline)

                Text("As you work out, your avatar will:")
                    .font(.subheadline)

                HStack(spacing: 20) {
                    Label("Get Stronger", systemImage: "arrow.up.circle.fill")
                    Label("Get Leaner", systemImage: "flame.fill")
                    Label("Unlock Colors", systemImage: "paintpalette.fill")
                }
                .font(.caption)
            }
            .padding()
            .background(Color.blue.opacity(0.1))
            .cornerRadius(12)

            Spacer()

            // Action buttons
            HStack(spacing: 20) {
                Button("Edit Avatar") {
                    dismiss()
                }
                .buttonStyle(.bordered)

                Button("Let's Go!") {
                    isComplete = true
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding()
        .desktopSheetFrame(width: 700, height: 650)
        .onAppear {
            blobAvatar = BlobAvatar3D(profile: profile)
        }
    }
}

// MARK: - Avatar Display View (for main app)
struct AvatarDisplayView: View {
    @Binding var profile: AvatarBodyProfile
    var showFullScreen: Bool = false

    @State private var blobAvatar: BlobAvatar3D?
    @State private var isAnimating = false

    var body: some View {
        VStack(spacing: 12) {
            // 3D Avatar
            if let avatar = blobAvatar {
                SceneView(
                    scene: avatar.getScene(),
                    options: [.allowsCameraControl, .autoenablesDefaultLighting]
                )
                .frame(height: showFullScreen ? 500 : 300)
                .background(Color.black.opacity(0.05))
                .cornerRadius(12)
                .onAppear {
                    avatar.startIdleAnimation()
                }
            }

            // Stats
            if !showFullScreen {
                HStack(spacing: 20) {
                    VStack {
                        Text("\(profile.muscleLevel)")
                            .font(.title2.bold())
                        Text("Muscle")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }

                    VStack {
                        Text("\(profile.leanLevel)")
                            .font(.title2.bold())
                        Text("Lean")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }

                    VStack {
                        Text(profile.skinColor.rawValue)
                            .font(.title2.bold())
                        Text("Color")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
                .padding()
            }

            // Action buttons
            HStack(spacing: 12) {
                Button("Squat") {
                    blobAvatar?.performSquat()
                }
                .buttonStyle(.bordered)

                Button("Jump") {
                    blobAvatar?.performJumpingJack()
                }
                .buttonStyle(.bordered)

                Button("Celebrate") {
                    blobAvatar?.celebrate()
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .onAppear {
            blobAvatar = BlobAvatar3D(profile: profile)
        }
        .onChange(of: profile) { newProfile in
            blobAvatar?.updateProfile(newProfile)
        }
    }
}

// MARK: - Avatar Evolution Notification
struct AvatarEvolutionNotification: View {
    let oldProfile: AvatarBodyProfile
    let newProfile: AvatarBodyProfile

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "arrow.up.circle.fill")
                .font(.system(size: 48))
                .foregroundColor(.green)

            Text("Your Avatar Evolved!")
                .font(.title.bold())

            Text(AvatarEvolutionEngine.getProgressDescription(newProfile))
                .font(.subheadline)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)

            HStack(spacing: 40) {
                VStack {
                    Text("\(oldProfile.muscleLevel) → \(newProfile.muscleLevel)")
                        .font(.headline)
                    Text("Muscle")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                VStack {
                    Text("\(oldProfile.leanLevel) → \(newProfile.leanLevel)")
                        .font(.headline)
                    Text("Lean")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
        }
        .adaptivePadding(30)
        .background(Color.platformWindowBackground)
        .cornerRadius(16)
        .shadow(radius: 20)
    }
}
