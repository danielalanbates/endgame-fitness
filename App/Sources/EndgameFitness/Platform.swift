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
import UniformTypeIdentifiers

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
typealias PlatformImage = NSImage
#else
typealias PlatformColor = UIColor
typealias PlatformImage = UIImage
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
    /// Puts plain text on the system pasteboard.
    static func copyToClipboard(_ text: String) {
        #if os(macOS)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        #else
        UIPasteboard.general.string = text
        #endif
    }

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

    /// Impact haptic used by the session game layer. No-op on the Mac.
    enum ImpactStrength { case light, medium, heavy }
    static func impact(_ strength: ImpactStrength) {
        #if os(iOS)
        let style: UIImpactFeedbackGenerator.FeedbackStyle
        switch strength {
        case .light: style = .light
        case .medium: style = .medium
        case .heavy: style = .heavy
        }
        UIImpactFeedbackGenerator(style: style).impactOccurred()
        #endif
    }

    /// Put an image on the general pasteboard (share-card "copy" on the Mac).
    static func copyImageToPasteboard(_ image: PlatformImage) {
        #if os(macOS)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.writeObjects([image])
        #else
        UIPasteboard.general.image = image
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

    /// True inside the App Sandbox (always on iOS; TestFlight/App Store builds
    /// on the Mac). The unsandboxed local Mac build may read ~/Documents; a
    /// sandboxed build never reaches outside its container without a panel.
    static var isSandboxed: Bool {
        #if os(macOS)
        ProcessInfo.processInfo.environment["APP_SANDBOX_CONTAINER_ID"] != nil
        #else
        true
        #endif
    }

    /// Dismisses the on-screen keyboard (number pads have no return key).
    static func dismissKeyboard() {
        #if os(iOS)
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
        #endif
    }
}

// MARK: - Split layout

/// `HSplitView` is macOS-only. This keeps the split layout in `ContentView`
/// platform-neutral. iOS no longer routes through here — it uses a TabView —
/// so in practice this is the macOS path plus a safe fallback.
struct PlatformSplit<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        #if os(macOS)
        HSplitView { content }
        #else
        HStack(spacing: 0) { content }
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
/// blocking panel: views there present `.fileExporter` / `.fileImporter` with
/// `WorkoutExportDocument` instead, so these functions are macOS-only in effect.
enum WorkoutTransfer {
    /// Writes `data` somewhere the user chose. Returns the destination, or nil if
    /// they cancelled, the write failed, or the platform has no panel.
    @discardableResult
    static func exportJSON(_ data: Data, suggestedName: String) -> URL? {
        #if os(macOS)
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = suggestedName
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        do {
            try data.write(to: url, options: .atomic)
            return url
        } catch {
            return nil
        }
        #else
        return nil
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
        return nil
        #endif
    }

    /// Reads a file handed over by `.fileImporter`, which grants
    /// security-scoped access that must be opened and closed around the read.
    static func readPickedFile(_ url: URL) -> Data? {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        return try? Data(contentsOf: url)
    }
}

/// The workout export as a document, for `.fileExporter` (iOS share/save).
struct WorkoutExportDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.json] }
    var data: Data

    init(data: Data) { self.data = data }

    init(configuration: ReadConfiguration) throws {
        data = configuration.file.regularFileContents ?? Data()
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}

// MARK: - Adaptive layout

/// The UI was laid out for a 900x700 macOS window. These helpers keep that
/// look on the Mac and relax it on a 390pt-wide iPhone without forking views.
extension Font {
    /// Page heading: `.largeTitle` on the Mac, `.title2` on iPhone.
    static var screenTitle: Font { Platform.isDesktop ? .largeTitle : .title2 }
}

extension View {
    /// Minimum window frame on the Mac. iOS fills whatever the screen gives.
    @ViewBuilder
    func desktopMinFrame(minWidth: CGFloat, minHeight: CGFloat) -> some View {
        if Platform.isDesktop {
            frame(minWidth: minWidth, minHeight: minHeight)
        } else {
            frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    /// Fixed sheet size on the Mac; iOS sheets already fill the screen.
    @ViewBuilder
    func desktopSheetFrame(width: CGFloat, height: CGFloat) -> some View {
        if Platform.isDesktop {
            frame(width: width, height: height)
        } else {
            frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    /// Fixed width on the Mac; on iPhone the view can shrink to fit but never
    /// grows past the same width.
    @ViewBuilder
    func desktopWidth(_ width: CGFloat) -> some View {
        if Platform.isDesktop {
            frame(width: width)
        } else {
            frame(maxWidth: width)
        }
    }

    /// Generous Mac padding, capped on iPhone so cards keep their content width.
    func adaptivePadding(_ desktop: CGFloat, phone: CGFloat = 16) -> some View {
        padding(Platform.isDesktop ? desktop : phone)
    }

    /// Wraps tall content in a vertical ScrollView on iPhone only.
    @ViewBuilder
    func scrollableOnPhone() -> some View {
        if Platform.isDesktop {
            self
        } else {
            // iOS 26 floats the tab bar over the content, so the last rows
            // of any scroll view are clipped without extra bottom inset.
            ScrollView(.vertical, showsIndicators: false) {
                self.padding(.bottom, 96)
            }
        }
    }

    /// Long headings: allow wrapping and shrink a little before clipping.
    func adaptiveHeading() -> some View {
        self
            .multilineTextAlignment(.center)
            .lineLimit(nil)
            .minimumScaleFactor(0.75)
            .frame(maxWidth: .infinity)
    }
}

/// Side-by-side on the Mac, stacked on iPhone.
struct AdaptiveHStack<Content: View>: View {
    var alignment: VerticalAlignment = .top
    var spacing: CGFloat = 16
    @ViewBuilder var content: Content

    var body: some View {
        let layout = Platform.isDesktop
            ? AnyLayout(HStackLayout(alignment: alignment, spacing: spacing))
            : AnyLayout(VStackLayout(alignment: .leading, spacing: spacing))
        layout { content }
    }
}

/// Fixed column count on the Mac, fewer on iPhone.
func adaptiveColumns(desktop: Int, phone: Int, spacing: CGFloat? = nil) -> [GridItem] {
    Array(repeating: GridItem(.flexible(), spacing: spacing), count: Platform.isDesktop ? desktop : phone)
}

// MARK: - Segmented controls

#if !os(macOS)
/// `UISegmentedControl` truncates its titles with a tail ellipsis instead of
/// shrinking them, so on a 390pt-wide iPhone (14/15 base width) a three- or
/// four-segment control silently eats whole words. None of that is reachable
/// from SwiftUI — `.font`/`.minimumScaleFactor` on the `Text` inside a
/// `Picker(.segmented)` are dropped, because the labels are turned into plain
/// title strings. The fix has to happen on the UIKit appearance proxy.
@MainActor
enum SegmentedControlAppearance {
    private static var configured = false

    /// Idempotent; safe to call from a view body.
    static func configure() {
        guard !configured else { return }
        configured = true

        let proxy = UISegmentedControl.appearance()
        // Size each segment to its own title rather than forcing width/count,
        // so one long label no longer clips every other segment.
        proxy.apportionsSegmentWidthsByContent = true

        let base = UIFont.preferredFont(forTextStyle: .footnote)
        proxy.setTitleTextAttributes([.font: base], for: .normal)
        let boldDescriptor = base.fontDescriptor.withSymbolicTraits(.traitBold) ?? base.fontDescriptor
        proxy.setTitleTextAttributes(
            [.font: UIFont(descriptor: boldDescriptor, size: base.pointSize)],
            for: .selected
        )
    }
}
#endif

extension View {
    /// `.pickerStyle(.segmented)` that stays readable at 390pt on iPhone.
    ///
    /// Use this instead of `.pickerStyle(.segmented)` everywhere in the app so
    /// segmented controls are sized and typeset consistently on both platforms.
    func compactSegmentedPicker() -> some View {
        #if os(macOS)
        return self.pickerStyle(.segmented)
        #else
        SegmentedControlAppearance.configure()
        return self
            .pickerStyle(.segmented)
            .font(.footnote)
            .minimumScaleFactor(0.75)
            .lineLimit(1)
        #endif
    }
}
