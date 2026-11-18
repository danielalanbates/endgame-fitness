//
//  AvatarViews.swift
//  SwiftUI views for the blob avatar: the creator, the 3D preview, and the
//  lightweight 2D badge used on player cards and rows (SceneKit is far too
//  heavy to put in a list).
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
            Text("Midsection shape?")
                .font(.system(size: 24, weight: .semibold))

            Text("No judgment, it's just a starting point for your avatar.")
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

                VStack(alignment: .leading, spacing: 6) {
                    Label("Build muscle as your lifetime volume grows", systemImage: "arrow.up.circle.fill")
                    Label("Unlock new colors as you level up", systemImage: "paintpalette.fill")
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

// MARK: - 2D badge (cards and rows)

/// The player's avatar as a small 2D portrait, with the equipped aura as a
/// ring. Without an avatar it falls back to the level in a rank-coloured disc.
struct AvatarBadgeView: View {
    let config: AvatarBodyProfile?
    let level: Int
    var cosmetic: String?
    var size: CGFloat = 52
    var tint: Color = .brandPurple

    var body: some View {
        ZStack {
            if let config {
                Circle()
                    .fill(LinearGradient(colors: [tint.opacity(0.30), tint.opacity(0.10)],
                                         startPoint: .top, endPoint: .bottom))
                BlobFigure(config: config)
                    .padding(size * 0.12)
                    .clipShape(Circle())
            } else {
                Circle()
                    .fill(LinearGradient(colors: [tint, tint.opacity(0.5)],
                                         startPoint: .topLeading, endPoint: .bottomTrailing))
                Text("\(level)")
                    .font(.system(size: size * 0.38, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                    .minimumScaleFactor(0.5)
            }
            if let cosmetic, !cosmetic.isEmpty {
                auraRing(cosmetic.auraColor)
            }
        }
        .frame(width: size, height: size)
        .overlay(alignment: .bottomTrailing) {
            if config != nil && size >= 40 {
                levelPill
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Level \(level) avatar")
    }

    private func auraRing(_ color: Color) -> some View {
        Circle()
            .strokeBorder(color, lineWidth: max(2, size * 0.05))
            .padding(-size * 0.07)
            .shadow(color: color.opacity(0.6), radius: size * 0.08)
    }

    private var levelPill: some View {
        Text("\(level)")
            .font(.system(size: max(9, size * 0.2), weight: .bold, design: .rounded))
            .foregroundStyle(.white)
            .padding(.horizontal, 4)
            .background(Capsule().fill(tint))
            .offset(x: 2, y: 2)
    }
}

/// Flat drawing of the blob: proportions from the questionnaire, muscle from
/// progress, a face once it is unlocked.
struct BlobFigure: View {
    let config: AvatarBodyProfile

    var body: some View {
        Canvas { context, size in
            draw(in: &context, size: size)
        }
    }

    private func draw(in context: inout GraphicsContext, size: CGSize) {
        let w = size.width, h = size.height
        let build = CGFloat(config.bodyType.baseScale)
        let tall = CGFloat(config.height.scaleY)
        let muscle = CGFloat(config.muscleLevel) / 100
        let shading = bodyShading(size: size)

        // Legs
        let legW = w * 0.12
        let legH = h * 0.24 * tall
        for x in [w * 0.40, w * 0.60] {
            let leg = CGRect(x: x - legW / 2, y: h - legH - h * 0.02, width: legW, height: legH)
            context.fill(Path(roundedRect: leg, cornerRadius: legW / 2), with: shading)
        }

        // Torso
        let torsoW = w * 0.42 * build * (1 + 0.18 * muscle)
        let torsoH = h * 0.40 * tall
        let torso = CGRect(x: (w - torsoW) / 2, y: h * 0.74 - torsoH, width: torsoW, height: torsoH)
        context.fill(Path(ellipseIn: torso), with: shading)

        // Arms
        let armW = w * 0.11 * (1 + 0.4 * muscle)
        let armH = torsoH * 0.75
        for side: CGFloat in [-1, 1] {
            let cx = w / 2 + side * (torsoW / 2 + armW * 0.2)
            let arm = CGRect(x: cx - armW / 2, y: torso.minY + torsoH * 0.12, width: armW, height: armH)
            context.fill(Path(roundedRect: arm, cornerRadius: armW / 2), with: shading)
        }

        // Head
        let headR = w * 0.16
        let head = CGRect(x: w / 2 - headR, y: torso.minY - headR * 1.75, width: headR * 2, height: headR * 2)
        context.fill(Path(ellipseIn: head), with: shading)

        if config.hasEyes {
            let eyeR = headR * 0.16
            for side: CGFloat in [-1, 1] {
                let eye = CGRect(x: head.midX + side * headR * 0.38 - eyeR,
                                 y: head.midY - eyeR * 1.4, width: eyeR * 2, height: eyeR * 2)
                context.fill(Path(ellipseIn: eye), with: .color(.black.opacity(0.8)))
            }
        }
        if config.hasMouth {
            var mouth = Path()
            mouth.addArc(center: CGPoint(x: head.midX, y: head.midY + headR * 0.18),
                         radius: headR * 0.32, startAngle: .degrees(20), endAngle: .degrees(160),
                         clockwise: false)
            context.stroke(mouth, with: .color(.black.opacity(0.7)), lineWidth: max(1, headR * 0.1))
        }
    }

    private func bodyShading(size: CGSize) -> GraphicsContext.Shading {
        if config.skinColor == .rainbow {
            return .linearGradient(
                Gradient(colors: [.red, .orange, .yellow, .green, .blue, .purple]),
                startPoint: .zero, endPoint: CGPoint(x: size.width, y: size.height)
            )
        }
        return .color(config.skinColor.swatch)
    }
}

/// "Juggernaut"-style capsule for the class the server derived.
struct HeroClassBadge: View {
    let hero: HeroClass
    var compact = false

    var body: some View {
        Label(hero.name, systemImage: hero.icon)
            .font(compact ? .caption2.weight(.bold) : .caption.weight(.bold))
            .foregroundStyle(hero.tint)
            .padding(.horizontal, compact ? 6 : 8)
            .padding(.vertical, compact ? 2 : 3)
            .background(Capsule().fill(hero.tint.opacity(0.15)))
            .lineLimit(1)
            .fixedSize()
            .help(hero.blurb)
            .accessibilityLabel("Class: \(hero.name)")
    }
}
