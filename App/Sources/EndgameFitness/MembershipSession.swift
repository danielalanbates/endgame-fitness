// Copyright (c) 2026 Daniel Bates / Bates LLC. All rights reserved.
// Uses BatesAI's shared Google/Apple membership login and one-use PKCE handoff.
import SwiftUI
import AuthenticationServices
import CryptoKit
import Security

@MainActor
final class MembershipSession: NSObject, ObservableObject {
    static let shared = MembershipSession()

    enum Provider: String, CaseIterable, Identifiable {
        case google, apple
        var id: String { rawValue }
        var title: String { self == .google ? "Google" : "Apple" }
    }

    struct User: Decodable {
        let id: String
        let display_name: String
        let friend_code: String
    }
    private struct UserEnvelope: Decodable { let user: User }
    private struct TokenEnvelope: Decodable { let token: String }

    @Published var user: User?
    @Published var loading = true
    @Published var busy = false
    @Published var error: String?
    private var authentication: ASWebAuthenticationSession?
    private var token: String? { get { Self.readToken() } set { Self.writeToken(newValue) } }
    private let api = "https://batesai.org/api/"
    private let endgame = "https://batesai.org/api/endgame/"
    private var restored = false

    func restore() async {
        guard !restored else { return }
        restored = true
        defer { loading = false }
        guard token != nil else { return }
        do { try await loadUser() }
        catch { self.error = "Reconnect to verify your BatesAI account. Your training data is preserved." }
    }

    private func loadUser() async throws {
        var request = URLRequest(url: URL(string: endgame + "me")!)
        request.setValue("Bearer \(token ?? "")", forHTTPHeaderField: "Authorization")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            token = nil
            throw URLError(.userAuthenticationRequired)
        }
        user = try JSONDecoder().decode(UserEnvelope.self, from: data).user
        selectPlayer()
    }

    /// The first BatesAI connection adopts the selected local player once. Later
    /// accounts get a separate local player, while existing answers remain intact.
    func selectPlayer() {
        guard let user else { return }
        let defaults = UserDefaults.standard
        var links = defaults.dictionary(forKey: "ef.membership.playerLinks") as? [String: String] ?? [:]
        let players = LocalPlayerStore.shared
        if let id = links[user.id], players.players.contains(where: { $0.id == id }) {
            if players.currentID == id { GameProfileService.shared.activate() }
            else { players.select(id) }
            return
        }
        let selected: LocalPlayer
        if links.isEmpty, let existing = players.current {
            selected = existing
        } else {
            selected = players.create(name: user.display_name, symbol: LocalPlayer.symbols[0], colorIndex: 0, pin: nil)
        }
        links[user.id] = selected.id
        defaults.set(links, forKey: "ef.membership.playerLinks")
        players.select(selected.id)
    }

    func signIn(with provider: Provider) {
        guard !busy else { return }
        busy = true
        error = nil
        let verifier = Self.randomVerifier()
        let challenge = Self.challenge(for: verifier)
        var components = URLComponents(string: api + "auth/oauth/\(provider.rawValue)")!
        components.queryItems = [
            URLQueryItem(name: "native", value: "1"),
            URLQueryItem(name: "challenge", value: challenge),
        ]
        guard let url = components.url else {
            busy = false
            error = "Could not open BatesAI sign-in. Please try again."
            return
        }

        let session = ASWebAuthenticationSession(url: url, callbackURLScheme: "endgamefitness") { [weak self] callback, failure in
            Task { @MainActor in
                guard let self else { return }
                defer { self.busy = false; self.authentication = nil }
                guard let callback, callback.host == "auth" else {
                    self.error = failure == nil
                        ? "BatesAI could not finish sign-in."
                        : "Sign-in was cancelled or unavailable. Your progress is safe."
                    return
                }
                let callbackItems = URLComponents(url: callback, resolvingAgainstBaseURL: false)?.queryItems ?? []
                if let reason = callbackItems.first(where: { $0.name == "error" })?.value {
                    self.error = reason == "cancelled"
                        ? "Sign-in was cancelled. Your progress is safe."
                        : "BatesAI could not finish sign-in. Please try again."
                    return
                }
                guard let code = callbackItems.first(where: { $0.name == "code" })?.value else {
                    self.error = "BatesAI could not finish sign-in. Please try again."
                    return
                }
                do {
                    var request = URLRequest(url: URL(string: self.api + "auth/native/handoff")!)
                    request.httpMethod = "POST"
                    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                    request.httpBody = try JSONSerialization.data(withJSONObject: ["code": code, "verifier": verifier])
                    let (data, response) = try await URLSession.shared.data(for: request)
                    guard (response as? HTTPURLResponse)?.statusCode == 200 else {
                        throw URLError(.userAuthenticationRequired)
                    }
                    self.token = try JSONDecoder().decode(TokenEnvelope.self, from: data).token
                    try await self.loadUser()
                } catch {
                    self.error = "BatesAI could not verify this sign-in. Please try again."
                }
            }
        }
        session.presentationContextProvider = self
        authentication = session
        if !session.start() {
            busy = false
            authentication = nil
            error = "Could not open the sign-in window. Please try again."
        }
    }

    func signOut() {
        let savedToken = token
        token = nil
        user = nil
        error = nil
        GameProfileService.shared.reset()
        // Keep the selected player and answers for the next verified sign-in.
        Task {
            guard let savedToken else { return }
            var request = URLRequest(url: URL(string: endgame + "logout")!)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue("Bearer \(savedToken)", forHTTPHeaderField: "Authorization")
            request.httpBody = Data("{}".utf8)
            _ = try? await URLSession.shared.data(for: request)
        }
    }

    private static func randomVerifier() -> String {
        UUID().uuidString.replacingOccurrences(of: "-", with: "")
            + UUID().uuidString.replacingOccurrences(of: "-", with: "")
    }

    private static func challenge(for verifier: String) -> String {
        Data(SHA256.hash(data: Data(verifier.utf8)))
            .base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private nonisolated static var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: "org.batesai.endgamefitness.membership",
         kSecAttrAccount as String: "session"]
    }
    private nonisolated static func readToken() -> String? {
        var q = query
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }
    private nonisolated static func writeToken(_ token: String?) {
        SecItemDelete(query as CFDictionary)
        guard let token else { return }
        var q = query
        q[kSecValueData as String] = Data(token.utf8)
        q[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        SecItemAdd(q as CFDictionary, nil)
    }
}

extension MembershipSession: ASWebAuthenticationPresentationContextProviding {
    nonisolated func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        MainActor.assumeIsolated {
            #if os(macOS)
            NSApplication.shared.windows.first { $0.isKeyWindow } ?? NSApplication.shared.windows.first ?? ASPresentationAnchor()
            #else
            UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first?.keyWindow ?? ASPresentationAnchor()
            #endif
        }
    }
}

struct MembershipSignInView: View {
    @ObservedObject private var auth = MembershipSession.shared
    var body: some View {
        VStack(spacing: 22) {
            Image(systemName: "figure.strengthtraining.traditional")
                .font(.system(size: 60)).foregroundStyle(Color.brandPurple)
            Text("Endgame Fitness").font(.largeTitle.bold())
            Text("Real training. Epic progress. Your next level.").foregroundStyle(.secondary)
            if auth.loading {
                SwiftUI.ProgressView("Restoring your session…")
            } else {
                Button(auth.busy ? "Connecting…" : "Continue with Google") {
                    auth.signIn(with: .google)
                }
                .buttonStyle(.borderedProminent).disabled(auth.busy)
                Button(auth.busy ? "Connecting…" : "Continue with Apple") {
                    auth.signIn(with: .apple)
                }
                .buttonStyle(.bordered).disabled(auth.busy)
                Text("Use your existing BatesAI account. Your training answers stay on this Mac.")
                    .font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
                if let error = auth.error { Text(error).foregroundStyle(.red).frame(maxWidth: 470) }
                Link("Privacy and data", destination: URL(string: "https://batesai.org/endgamefitness/privacy.html")!)
            }
        }
        .padding(40).frame(maxWidth: .infinity, maxHeight: .infinity)
        .task { await auth.restore() }
    }
}
