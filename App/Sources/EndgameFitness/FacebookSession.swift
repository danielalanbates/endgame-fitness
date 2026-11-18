// Copyright (c) 2026 Daniel Bates / Bates LLC. All rights reserved.
// Facebook-only sign-in. Native handoff uses a one-time code bound to PKCE;
// provider access tokens and the Meta app secret never leave the server.
import SwiftUI
import AuthenticationServices
import CryptoKit
import Security

@MainActor
final class FacebookSession: NSObject, ObservableObject {
    static let shared = FacebookSession()
    struct User: Decodable { let id: String; let display_name: String; let friend_code: String }
    private struct Envelope: Decodable { let user: User }
    private struct Exchange: Decodable { let token: String }
    @Published var user: User?
    @Published var loading = true
    @Published var busy = false
    @Published var error: String?
    private var authentication: ASWebAuthenticationSession?
    private var token: String? { get { Self.readToken() } set { Self.writeToken(newValue) } }
    private let base = "https://batesai.org/api/endgame/"
    private var restored = false

    func restore() async {
        guard !restored else { return }; restored = true
        defer { loading = false }
        guard token != nil else { return }
        do { try await loadUser() } catch { self.error = "Reconnect to verify your Facebook session. Your training data is preserved." }
    }
    private func loadUser() async throws {
        var request = URLRequest(url: URL(string: base + "me")!)
        request.setValue("Bearer \(token ?? "")", forHTTPHeaderField: "Authorization")
        let (data,response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.userAuthenticationRequired) }
        user = try JSONDecoder().decode(Envelope.self, from: data).user
        selectPlayer()
    }
    /// The first Facebook connection adopts the existing selected profile once.
    /// Subsequent Facebook identities get their own profile and never auto-adopt.
    func selectPlayer() {
        guard let user else { return }
        let defaults = UserDefaults.standard
        var links = defaults.dictionary(forKey: "ef.facebook.playerLinks") as? [String:String] ?? [:]
        let players = LocalPlayerStore.shared
        if let id = links[user.id], players.players.contains(where: { $0.id == id }) {
            if players.currentID == id { GameProfileService.shared.activate() } else { players.select(id) }; return
        }
        let selected: LocalPlayer
        if links.isEmpty, let existing = players.current { selected = existing }
        else { selected = players.create(name: user.display_name, symbol: LocalPlayer.symbols[0], colorIndex: 0, pin: nil) }
        links[user.id] = selected.id; defaults.set(links, forKey: "ef.facebook.playerLinks")
        players.select(selected.id)
    }
    func signIn() {
        guard !busy else { return }; busy = true; error = nil
        let verifier = UUID().uuidString.replacingOccurrences(of: "-", with: "") + UUID().uuidString.replacingOccurrences(of: "-", with: "")
        let challenge = Data(SHA256.hash(data: Data(verifier.utf8))).base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
        let url = URL(string: base + "auth/start?native=1&challenge=\(challenge)")!
        let session = ASWebAuthenticationSession(url: url, callbackURLScheme: "endgamefitness") { [weak self] callback, failure in
            Task { @MainActor in
                guard let self else { return }
                defer { self.busy = false; self.authentication = nil }
                guard let callback, callback.host == "auth", let code = URLComponents(url: callback, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "code" })?.value else {
                    self.error = failure == nil ? "Facebook could not finish sign-in." : "Sign-in was cancelled or unavailable. Your progress is safe."; return
                }
                do {
                    var request = URLRequest(url: URL(string: self.base + "native/exchange")!)
                    request.httpMethod = "POST"; request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                    request.httpBody = try JSONSerialization.data(withJSONObject: ["code":code,"verifier":verifier])
                    let (data,response) = try await URLSession.shared.data(for: request)
                    guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.userAuthenticationRequired) }
                    self.token = try JSONDecoder().decode(Exchange.self, from: data).token
                    try await self.loadUser()
                } catch { self.error = "Facebook sign-in could not be verified. Please try again." }
            }
        }
        session.presentationContextProvider = self
        authentication = session
        if !session.start() { busy = false; authentication = nil; error = "Could not open the Facebook sign-in window." }
    }
    func signOut() {
        let savedToken = token
        token = nil; user = nil; error = nil
        GameProfileService.shared.reset()
        // Keep the selected player and answers for the next verified sign-in.
        Task {
            guard let savedToken else { return }
            var request = URLRequest(url: URL(string: base + "logout")!)
            request.httpMethod = "POST"; request.setValue("Bearer \(savedToken)", forHTTPHeaderField: "Authorization")
            _ = try? await URLSession.shared.data(for: request)
        }
    }
    private nonisolated static var query: [String:Any] { [kSecClass as String:kSecClassGenericPassword,kSecAttrService as String:"org.batesai.endgamefitness.facebook",kSecAttrAccount as String:"session"] }
    private nonisolated static func readToken() -> String? {
        var q = query; q[kSecReturnData as String] = true; q[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?; guard SecItemCopyMatching(q as CFDictionary,&result) == errSecSuccess, let data = result as? Data else { return nil }
        return String(data:data,encoding:.utf8)
    }
    private nonisolated static func writeToken(_ token: String?) {
        SecItemDelete(query as CFDictionary)
        guard let token else { return }
        var q = query; q[kSecValueData as String] = Data(token.utf8); q[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        SecItemAdd(q as CFDictionary,nil)
    }
}
extension FacebookSession: ASWebAuthenticationPresentationContextProviding {
    nonisolated func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        MainActor.assumeIsolated {
            #if os(macOS)
            return NSApplication.shared.windows.first { $0.isKeyWindow } ?? NSApplication.shared.windows.first ?? ASPresentationAnchor()
            #else
            return UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first?.keyWindow ?? ASPresentationAnchor()
            #endif
        }
    }
}
struct FacebookSignInView: View {
    @ObservedObject private var auth = FacebookSession.shared
    @State private var available: Bool?
    var body: some View {
        VStack(spacing:22) {
            Image(systemName:"figure.strengthtraining.traditional").font(.system(size:60)).foregroundStyle(Color.brandPurple)
            Text("Endgame Fitness").font(.largeTitle.bold())
            Text("Real training. Epic progress. Your next level.").foregroundStyle(.secondary)
            if auth.loading { SwiftUI.ProgressView("Restoring your session…") }
            else {
                Button(auth.busy ? "Connecting…" : "Continue with Facebook") { auth.signIn() }
                    .buttonStyle(.borderedProminent).disabled(auth.busy || available != true)
                if available == false { Text("Facebook sign-in is awaiting Meta app configuration. Your existing workouts and onboarding answers are preserved.").foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth:470) }
                if let error = auth.error { Text(error).foregroundStyle(.red).frame(maxWidth:470) }
                Text("Facebook is the only sign-in provider. We never post automatically.").font(.caption).foregroundStyle(.secondary)
                Link("Privacy and data",destination:URL(string:"https://batesai.org/endgamefitness/privacy.html")!)
            }
        }.padding(40).frame(maxWidth:.infinity,maxHeight:.infinity)
        .task {
            await auth.restore()
            if let url = URL(string:"https://batesai.org/api/endgame/config"), let (data,_) = try? await URLSession.shared.data(from:url), let value = try? JSONSerialization.jsonObject(with:data) as? [String:Any] { available = value["facebook"] as? Bool ?? false }
            else { available = false }
        }
    }
}
