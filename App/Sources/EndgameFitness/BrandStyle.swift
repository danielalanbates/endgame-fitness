//
//  BrandStyle.swift
//  Endgame Fitness
//
//  One home for the app's colours and gradients. The look is carried over
//  from the late-2025 build: purple→blue gradient titles, a tinted sidebar
//  with coloured tab pills, big gradient call-to-action cards, soft pastel
//  insight cards and a gradient launch splash. Views use these tokens
//  instead of colour literals so the palette changes in one place.
//

import SwiftUI

// MARK: - Brand colours

extension Color {
    static let brandPurple = Color(red: 0.58, green: 0.40, blue: 0.93)
    static let brandBlue = Color(red: 0.33, green: 0.67, blue: 0.93)
    static let brandGreen = Color(red: 0.40, green: 0.87, blue: 0.67)
    static let brandOrange = Color(red: 1.0, green: 0.60, blue: 0.40)
    static let brandYellow = Color(red: 1.0, green: 0.87, blue: 0.40)
    /// Amber that stays readable as text on a light background (yellow does not).
    static let brandAmber = Color(red: 0.86, green: 0.60, blue: 0.05)

    static let lightPurpleBg = Color(red: 0.95, green: 0.93, blue: 0.98)
    static let lightBlueBg = Color(red: 0.93, green: 0.96, blue: 0.99)
    static let lightGreenBg = Color(red: 0.93, green: 0.98, blue: 0.96)
    static let lightOrangeBg = Color(red: 1.0, green: 0.96, blue: 0.93)
}

// MARK: - Gradient tokens

enum Brand {
    /// Page titles and the sidebar wordmark: purple → blue, left to right.
    static let title = LinearGradient(colors: [.brandPurple, .brandBlue],
                                      startPoint: .leading, endPoint: .trailing)

    /// Primary call-to-action cards.
    static let hero = LinearGradient(colors: [Color(red: 0.72, green: 0.30, blue: 0.86), .brandPurple, .brandBlue],
                                     startPoint: .leading, endPoint: .trailing)

    /// The call-to-action card once today's work is done.
    static let heroDone = LinearGradient(colors: [Color(red: 0.20, green: 0.70, blue: 0.55), .brandGreen],
                                         startPoint: .leading, endPoint: .trailing)

    /// Full-window launch splash: purple → blue → teal.
    static let splash = LinearGradient(colors: [.brandPurple, .brandBlue, .brandGreen],
                                       startPoint: .topLeading, endPoint: .bottomTrailing)

    /// Sidebar wash, fading into the normal control background.
    static let sidebar = LinearGradient(colors: [Color.brandPurple.opacity(0.16),
                                                 Color.brandBlue.opacity(0.10),
                                                 Color.platformControlBackground],
                                        startPoint: .top, endPoint: .bottom)

    /// Soft pastel card fill. Dark mode needs a stronger tint to read at all.
    static func softCard(_ scheme: ColorScheme) -> LinearGradient {
        let a = scheme == .dark ? 0.22 : 0.10
        return LinearGradient(colors: [Color.brandBlue.opacity(a), Color.brandPurple.opacity(a),
                                       Color.pink.opacity(a * 0.6)],
                              startPoint: .topLeading, endPoint: .bottomTrailing)
    }

    /// Sidebar tab colours, as in the 2025 build.
    enum Tab {
        static let dashboard = Color.red
        static let workouts = Color.orange
        static let programs = Color.brandAmber
        static let progress = Color.green
        static let mesocycle = Color.cyan
        static let tools = Color.blue
        static let community = Color.purple
        static let settings = Color.gray
    }

    /// Art from the asset catalog.
    static let dragonLogo = "DragonLogo"
}

// MARK: - Modifiers

extension View {
    /// Purple → blue gradient fill for a page heading.
    func brandTitle() -> some View {
        foregroundStyle(Brand.title)
    }

    /// The soft pastel card background used by the dashboard's insight cards.
    func brandSoftCard(cornerRadius: CGFloat = 12) -> some View {
        modifier(BrandSoftCard(cornerRadius: cornerRadius))
    }
}

private struct BrandSoftCard: ViewModifier {
    let cornerRadius: CGFloat
    @Environment(\.colorScheme) private var scheme

    func body(content: Content) -> some View {
        content
            .background(Brand.softCard(scheme), in: RoundedRectangle(cornerRadius: cornerRadius))
            .shadow(color: Color.black.opacity(scheme == .dark ? 0 : 0.05), radius: 5, x: 0, y: 2)
    }
}

// MARK: - Dragon logo

/// The dragon emblem, tinted with the brand gradient (or any style).
struct DragonLogo<S: ShapeStyle>: View {
    var style: S

    var body: some View {
        Image(Brand.dragonLogo)
            .renderingMode(.template)
            .resizable()
            .interpolation(.high)
            .scaledToFit()
            .foregroundStyle(style)
            .accessibilityHidden(true)
    }
}

extension DragonLogo where S == LinearGradient {
    init() { self.style = Brand.title }
}

// MARK: - Hero card

/// A big gradient call-to-action card (the 2025 build's banner style).
struct BrandHeroCard: View {
    let icon: String
    let title: String
    let subtitle: String
    var gradient: LinearGradient = Brand.hero
    var trailingIcon: String = "arrow.right.circle.fill"
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 18) {
                Image(systemName: icon)
                    .font(.system(size: 34, weight: .semibold))
                    .foregroundStyle(Color.brandYellow, .white)
                    .frame(width: 44)
                VStack(alignment: .leading, spacing: 4) {
                    Text(title)
                        .font(.title2.bold())
                        .lineLimit(2)
                    Text(subtitle)
                        .font(.subheadline)
                        .opacity(0.9)
                        .lineLimit(2)
                }
                Spacer(minLength: 8)
                Image(systemName: trailingIcon)
                    .font(.system(size: 30))
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 22)
            .padding(.vertical, 20)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(gradient, in: RoundedRectangle(cornerRadius: 16))
            .shadow(color: .brandPurple.opacity(0.3), radius: 10, y: 5)
            .contentShape(RoundedRectangle(cornerRadius: 16))
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Launch splash

/// Gradient splash shown briefly over the first window at launch. It sits on
/// top of whatever RootView is showing (player picker, onboarding or the app),
/// never replaces it, and a click dismisses it at once.
struct BrandSplashView: View {
    let onFinish: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var shown = false
    @State private var line = BrandSplashView.lines.randomElement() ?? ""

    static let lines = [
        "The only bad workout is the one that didn't happen.",
        "Success is the sum of small efforts repeated day in and day out.",
        "Don't limit your challenges. Challenge your limits.",
        "Great things never come from comfort zones.",
        "Don't stop when you're tired. Stop when you're done.",
        "Wake up with determination. Go to bed with satisfaction.",
        "Strong roots, strong future.",
    ]

    /// Visible time before it fades on its own.
    static let duration: TimeInterval = 1.5

    private static var claimed = false
    /// True the first time it is called in this process, so only the first
    /// window shows the splash. `-ef.noSplash` turns it off.
    static func claimLaunch() -> Bool {
        guard !claimed, !CommandLine.arguments.contains("-ef.noSplash") else { return false }
        claimed = true
        return true
    }

    var body: some View {
        ZStack {
            Brand.splash.ignoresSafeArea()

            VStack(spacing: 28) {
                Image(systemName: "dumbbell.fill")
                    .font(.system(size: 88))
                    .foregroundStyle(LinearGradient(colors: [.white, .white.opacity(0.8)],
                                                    startPoint: .top, endPoint: .bottom))
                    .scaleEffect(shown || reduceMotion ? 1 : 0.85)
                Text("Endgame Fitness")
                    .font(.system(size: 44, weight: .bold))
                    .foregroundStyle(.white)
                Text(line)
                    .font(.system(size: 19, weight: .medium))
                    .foregroundStyle(.white.opacity(0.95))
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 48)
            }
            .opacity(shown ? 1 : 0)
        }
        .contentShape(Rectangle())
        .onTapGesture(perform: onFinish)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityHint("Click to continue")
        .task {
            withAnimation(reduceMotion ? .none : .easeOut(duration: 0.6)) { shown = true }
            try? await Task.sleep(nanoseconds: UInt64(Self.duration * 1_000_000_000))
            onFinish()
        }
    }
}
