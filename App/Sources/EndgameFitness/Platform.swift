//
//  Platform.swift
//  Endgame Fitness
//
//  The app began life as a macOS-only target and reached directly for AppKit in
//  a handful of places. Rather than fork the source for iOS, every one of those
//  touchpoints is funnelled through this file. Keep AppKit/UIKit imports here so
//  the rest of the codebase stays plain SwiftUI and compiles for both platforms.
//

import SwiftUI

#if os(macOS)
import AppKit
#else
import UIKit
#endif

// MARK: - Colors

/// The platform's concrete colour class. SceneKit materials and lights need a
/// real `NSColor`/`UIColor` rather than a SwiftUI `Color`, so the avatar system
/// builds against this alias instead of hard-coding AppKit.
#if os(macOS)
typealias PlatformColor = NSColor
#else
typealias PlatformColor = UIColor
#endif

/// The scalar `SCNVector3` is built from: `CGFloat` on macOS, `Float` on iOS.
/// This is a genuine API difference, not a Swift inference quirk, so every
/// vector component in the avatar system is funnelled through `scn(_:)` below.
#if os(macOS)
typealias SCNFloat = CGFloat
#else
typealias SCNFloat = Float
#endif

/// Converts any numeric value to the right scalar for `SCNVector3`.
@inline(__always)
func scn<T: BinaryFloatingPoint>(_ value: T) -> SCNFloat {
    SCNFloat(value)
}

extension Color {
    /// Background for inset cards and controls.
    static var platformControlBackground: Color {
        #if os(macOS)
        Color(NSColor.controlBackgroundColor)
        #else
        Color(UIColor.secondarySystemBackground)
        #endif
    }

    /// The window/page background behind everything else.
    static var platformWindowBackground: Color {
        #if os(macOS)
        Color(NSColor.windowBackgroundColor)
        #else
        Color(UIColor.systemBackground)
        #endif
    }

    /// Background for editable text fields.
    static var platformTextBackground: Color {
        #if os(macOS)
        Color(NSColor.textBackgroundColor)
        #else
        Color(UIColor.systemBackground)
        #endif
    }
}

// MARK: - Feedback

enum Platform {
    /// A short "that didn't work" cue. Audible on the Mac, haptic on iPhone.
    static func beep() {
        #if os(macOS)
        NSSound.beep()
        #else
        UINotificationFeedbackGenerator().notificationOccurred(.warning)
        #endif
    }

    /// A "you did it" cue used for set completion and level-ups.
    static func success() {
        #if os(iOS)
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        #endif
    }

    /// Light tick used when a rep or set is logged.
    static func tick() {
        #if os(iOS)
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        #endif
    }

    /// Bring the app forward. A no-op outside macOS, where the system decides.
    static func activate() {
        #if os(macOS)
        NSApp.activate(ignoringOtherApps: true)
        #endif
    }

    /// True where a window can be freely resized, which drives whether views ask
    /// for a minimum frame or fill the screen.
    static var isDesktop: Bool {
        #if os(macOS)
        true
        #else
        false
        #endif
    }
}

// MARK: - Cross-platform text field

/// The original `MacTextField` wrapped `NSTextField` to get first-responder and
/// tab-order behaviour that SwiftUI lacked at the time. On iOS the plain SwiftUI
/// `TextField` is the right control, so this shim picks per platform and keeps a
/// single call site in the onboarding flow.
struct PlatformTextField: View {
    let placeholder: String
    @Binding var text: String
    var isSecure: Bool = false
    var onCommit: () -> Void = {}

    var body: some View {
        Group {
            if isSecure {
                SecureField(placeholder, text: $text)
            } else {
                TextField(placeholder, text: $text)
            }
        }
        .textFieldStyle(.plain)
        .padding(10)
        .background(Color.platformTextBackground)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color.gray.opacity(0.3), lineWidth: 1)
        )
        .onSubmit(onCommit)
        #if os(iOS)
        .autocorrectionDisabled(true)
        .textInputAutocapitalization(.never)
        #endif
    }
}

// MARK: - File import / export

/// Export and import were built on `NSSavePanel`/`NSOpenPanel`. iOS has no
/// equivalent panel, so the JSON payload is produced here and the caller decides
/// how to present it (share sheet on iOS, save panel on macOS).
enum WorkoutTransfer {
    /// Writes `data` somewhere the user chose. Returns the destination, or nil if
    /// they cancelled or the platform has no panel.
    @discardableResult
    static func exportJSON(_ data: Data, suggestedName: String) -> URL? {
        #if os(macOS)
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = suggestedName
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        try? data.write(to: url)
        return url
        #else
        // On iOS write to the app's Documents directory; the caller presents a
        // share sheet for this URL.
        let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let url = dir.appendingPathComponent(suggestedName)
        try? data.write(to: url)
        return url
        #endif
    }

    /// Reads a JSON file the user picked. Returns nil if they cancelled.
    static func importJSON() -> Data? {
        #if os(macOS)
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        return try? Data(contentsOf: url)
        #else
        // iOS uses `.fileImporter` at the view layer instead of a blocking panel.
        return nil
        #endif
    }
}
