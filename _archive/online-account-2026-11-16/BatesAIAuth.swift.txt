//
//  BatesAIAuth.swift
//  Endgame Fitness
//
//  Sign-in against the batesai.org membership system (Docs/API_V2.md §1).
//
//  Three routes, all ending in a BatesAI session token:
//    • Sign in with Apple — native, via AuthenticationServices. The device hands
//      us an identity token signed by Apple; the server verifies it against
//      Apple's JWKS and returns our own token. Required by App Store review
//      whenever a third-party login is offered.
//    • Google — ASWebAuthenticationSession on the website's OAuth flow. The
//      server finishes the Google exchange, then bounces back to
//      endgamefitness://auth?code=… with a one-time handoff code (never the
//      session token itself), which we redeem with POST auth/handoff.
//    • Email + password — the same accounts the website and the PWA use.
//
//  The session token is kept in the Keychain, never UserDefaults: it is a
//  bearer credential for the user's whole BatesAI account.
//

import Foundation
import AuthenticationServices
import CryptoKit
import SwiftUI

// MARK: - Models

struct BatesAIUser: Codable, Identifiable, Equatable {
    let id: String
    let email: String
    let name: String?
    let avatarURL: String?
    let membership: String?

    enum CodingKeys: String, CodingKey {
        case id, email, name, membership
        case avatarURL = "avatar_url"
    }

    var displayName: String {
        if let name, !name.isEmpty { return name }
        return email.split(separator: "@").first.map(String.init) ?? "Athlete"
    }

    /// The website has used both names for the paid tier.
    var isPremium: Bool { membership == "premium" || membership == "pro" }
}

enum AuthError: LocalizedError {
    case cancelled
    case missingIdentityToken
    /// The response arrived but could not be understood.
    case server(String)
    /// A non-2xx response. `code` is the server's `error` field when it is a
    /// machine code (`rate_limited`, `title_not_earned`, …), `message` when it
    /// is a sentence meant for people.
    case http(status: Int, code: String?, message: String?, retryAfter: Int?)
    case network(String)
    case notSignedIn

    /// The HTTP status, when the server answered at all.
    var status: Int? {
        if case .http(let status, _, _, _) = self { return status }
        return nil
    }

    var errorDescription: String? {
        switch self {
        case .cancelled:             return "Sign-in was cancelled."
        case .missingIdentityToken:  return "Apple did not return an identity token. Please try again."
        case .server(let message):   return message
        case .network:               return "Can't reach batesai.org. Check your connection and try again."
        case .notSignedIn:           return "You are not signed in."
        case .http(let status, let code, let message, let retryAfter):
            if status == 429 || code == "rate_limited" {
                let minutes = max(1, Int((Double(retryAfter ?? 60) / 60).rounded(.up)))
                return "Too many attempts. Try again in \(minutes) min."
            }
            if let code, let friendly = Self.friendlyMessages[code] { return friendly }
            if let message, !message.isEmpty { return message }
            if status >= 500 { return "batesai.org is having trouble right now. Please try again shortly." }
            return "Request failed (\(code ?? "HTTP \(status)"))."
        }
    }

    /// Copy for the machine codes Docs/API_V2.md defines.
    private static let friendlyMessages: [String: String] = [
        "display_name_invalid": "That hero name isn't allowed. Use 2–24 letters, numbers, spaces or _ - . ' and keep it friendly.",
        "bio_invalid": "That bio isn't allowed. Keep it under 160 characters and friendly.",
        "title_not_earned": "You haven't earned that title yet.",
        "cosmetic_not_earned": "You haven't earned that aura yet.",
        "code_used": "That sign-in link was already used. Please sign in again.",
        "code_expired": "That sign-in link expired. Please sign in again.",
        "text_invalid": "That comment isn't allowed. Keep it under 280 characters and friendly.",
        "comment_invalid": "That comment isn't allowed. Keep it under 280 characters and friendly.",
        "not_found": "That no longer exists.",
        "guild_full": "That guild is full.",
        "invalid_code": "No guild has that invite code.",
    ]
}

// MARK: - Keychain

/// Minimal Keychain wrapper for the one secret this app stores.
///
/// On macOS the data-protection keychain is preferred (no ACL prompts after a
/// re-signed build); builds without the keychain entitlement fall back to the
/// legacy file keychain, which is also where older builds stored the token.
enum TokenStore {
    private static let service = "org.batesai.endgamefitness"
    private static let account = "session-token"

    private static var variants: [Bool] {
        #if os(macOS)
        return [true, false]
        #else
        return [false]
        #endif
    }

    private static func query(dataProtection: Bool) -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        #if os(macOS)
        if dataProtection { query[kSecUseDataProtectionKeychain as String] = true }
        #endif
        return query
    }

    static func save(_ token: String) {
        // Delete-then-add is the reliable way to overwrite; SecItemUpdate fails
        // when no item exists yet.
        clear()
        for dataProtection in variants {
            var attributes = query(dataProtection: dataProtection)
            attributes[kSecValueData as String] = Data(token.utf8)
            attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
            let status = SecItemAdd(attributes as CFDictionary, nil)
            if status == errSecSuccess { return }
            #if DEBUG
            print("TokenStore: SecItemAdd failed (\(status)), dataProtection=\(dataProtection)")
            #endif
        }
    }

    static func load() -> String? {
        for dataProtection in variants {
            var lookup = query(dataProtection: dataProtection)
            lookup[kSecReturnData as String] = true
            lookup[kSecMatchLimit as String] = kSecMatchLimitOne
            var item: CFTypeRef?
            if SecItemCopyMatching(lookup as CFDictionary, &item) == errSecSuccess,
               let data = item as? Data,
               let token = String(data: data, encoding: .utf8) {
                return token
            }
        }
        return nil
    }

    static func clear() {
        for dataProtection in variants {
            SecItemDelete(query(dataProtection: dataProtection) as CFDictionary)
        }
    }
}

// MARK: - Auth service

@MainActor
final class BatesAIAuth: NSObject, ObservableObject {
    static let shared = BatesAIAuth()

    /// The signed-in member. Changing to a different id (or to nil) tells the
    /// training log through `WorkoutSyncBridge.accountChanged`, so one account's
    /// local data never leaks into another's.
    @Published private(set) var user: BatesAIUser? {
        didSet {
            guard oldValue?.id != user?.id else { return }
            noteAccount(user?.id)
        }
    }
    @Published private(set) var isRestoring = true
    @Published var lastError: String?
    /// True while running on a stored session that could not be re-checked
    /// (offline at launch). Cleared by `revalidateIfNeeded()`.
    @Published private(set) var isOfflineSession = false

    /// True once we hold a token the server has confirmed (or, offline, a token
    /// it confirmed on an earlier launch).
    var isSignedIn: Bool { user != nil }

    private(set) var token: String? {
        didSet {
            if let token { TokenStore.save(token) } else { TokenStore.clear() }
        }
    }

    static let apiBase = URL(string: "https://batesai.org/api")!
    static let callbackScheme = "endgamefitness"
    static let helpEmail = "help@batesai.org"
    static let membershipURL = URL(string: "https://batesai.org/membership/")!

    /// Nonce for the in-flight Apple request. Apple embeds its SHA-256 in the
    /// identity token, which is what stops a captured token being replayed.
    private var currentNonce: String?
    private var webSession: ASWebAuthenticationSession?

    private static let defaults = UserDefaults.standard
    private static let cachedUserKey = "batesai.cachedUser"
    private static let lastAccountKey = "batesai.lastAccountID"
    private static let accountScopedKey = "batesai.accountScopedState"

    /// The account this device last had signed in, persisted across launches.
    /// nil after a sign-out. The training log can read this synchronously at
    /// launch, before the session has been re-verified.
    static var lastAccountID: String? {
        defaults.string(forKey: lastAccountKey)
    }

    private override init() {
        super.init()
        self.token = TokenStore.load()
    }

    // MARK: Session restore

    /// Called once at launch. Confirms a stored token is still valid.
    /// Only an HTTP 401 ends the session (API_V2 §1.2): a 5xx or a dead network
    /// keeps the token and, when possible, the cached account so the app still
    /// works offline.
    func restoreSession() async {
        defer { isRestoring = false }
        guard let token else { return }

        do {
            let response: VerifyResponse = try await request(
                "auth/verify", method: "GET", token: token
            )
            if response.valid, let user = response.user {
                adoptLegacyStateIfNeeded(for: user.id)
                setUser(user)
                isOfflineSession = false
            } else {
                signOutLocally()
            }
        } catch let error as AuthError where error.status == 401 {
            signOutLocally()
        } catch {
            if let cached = Self.loadCachedUser() {
                adoptLegacyStateIfNeeded(for: cached.id)
                self.user = cached
                isOfflineSession = true
            } else {
                lastError = error.localizedDescription
            }
        }
    }

    /// Re-checks an offline session once the app is back in the foreground.
    func revalidateIfNeeded() async {
        guard isOfflineSession, let token else { return }
        do {
            let response: VerifyResponse = try await request("auth/verify", method: "GET", token: token)
            if response.valid, let user = response.user {
                setUser(user)
                isOfflineSession = false
            } else {
                signOutLocally()
            }
        } catch let error as AuthError where error.status == 401 {
            signOutLocally()
        } catch {
            // Still offline; try again next time.
        }
    }

    // MARK: Sign in with Apple

    /// Configures the request the system Sign in with Apple button is about to
    /// send. Apple gets SHA-256(raw nonce); the raw value stays on the device.
    func prepareAppleRequest(_ request: ASAuthorizationAppleIDRequest) {
        lastError = nil
        let nonce = Self.randomNonce()
        currentNonce = nonce
        request.requestedScopes = [.fullName, .email]
        request.nonce = Self.sha256(nonce)
    }

    /// Finishes a Sign in with Apple attempt started by the system button.
    func completeAppleSignIn(_ result: Result<ASAuthorization, Error>) async {
        defer { currentNonce = nil }
        switch result {
        case .failure(let error):
            if let authError = error as? ASAuthorizationError, authError.code == .canceled {
                lastError = nil
            } else {
                lastError = error.localizedDescription
            }
        case .success(let authorization):
            do {
                guard let rawNonce = currentNonce else {
                    throw AuthError.server("Sign in with Apple was interrupted. Please try again.")
                }
                guard
                    let credential = authorization.credential as? ASAuthorizationAppleIDCredential,
                    let tokenData = credential.identityToken,
                    let identityToken = String(data: tokenData, encoding: .utf8)
                else { throw AuthError.missingIdentityToken }

                // Apple sends the user's name only on the very first
                // authorization, so forward it now or it is lost forever.
                var fullName: [String: String]?
                if let components = credential.fullName {
                    let given = components.givenName ?? ""
                    let family = components.familyName ?? ""
                    if !(given.isEmpty && family.isEmpty) {
                        fullName = ["givenName": given, "familyName": family]
                    }
                }

                // The identity token's `nonce` claim is the SHA-256 we put on the
                // request, and the server compares its `nonce` field to that claim
                // verbatim — so send the HASHED value. (Sending the raw nonce made
                // every real-device sign-in fail with 401 "Nonce mismatch";
                // simulator tokens omit the claim, which hid it.)
                var body: [String: Any] = ["identity_token": identityToken, "nonce": Self.sha256(rawNonce)]
                if let fullName { body["full_name"] = fullName }

                let response: SessionResponse = try await signInRequest("auth/native/apple", body: body)
                adopt(response)
            } catch {
                lastError = error.localizedDescription
            }
        }
    }

    // MARK: Sign in with Google

    /// The membership site's Google flow in the system browser sheet. The server
    /// holds the client secret and redeems Google's code; we only ever see a
    /// one-time handoff code (API_V2 §1.1).
    func signInWithGoogle() async {
        lastError = nil
        let url = Self.endpoint(
            "auth/oauth/google",
            query: [URLQueryItem(name: "redirect_scheme", value: Self.callbackScheme)]
        )

        do {
            let callbackURL = try await runWebAuthentication(url: url)
            let items = URLComponents(url: callbackURL, resolvingAgainstBaseURL: false)?.queryItems ?? []
            if let code = items.first(where: { $0.name == "code" })?.value, !code.isEmpty {
                let response: SessionResponse = try await signInRequest("auth/handoff", body: ["code": code])
                adopt(response)
            } else if let failure = items.first(where: { $0.name == "error" })?.value, !failure.isEmpty {
                throw AuthError.server(failure == "access_denied"
                    ? "Google sign-in was cancelled."
                    : "Google sign-in failed (\(failure)). Please try again.")
            } else {
                throw AuthError.server("Google sign-in did not finish. Please try again.")
            }
        } catch AuthError.cancelled {
            lastError = nil
        } catch {
            lastError = error.localizedDescription
        }
    }

    private func runWebAuthentication(url: URL) async throws -> URL {
        let once = ResumeOnce()
        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<URL, Error>) in
            let session = ASWebAuthenticationSession(
                url: url, callbackURLScheme: Self.callbackScheme
            ) { callback, error in
                guard once.claim() else { return }
                if let callback {
                    continuation.resume(returning: callback)
                } else if let error = error as? ASWebAuthenticationSessionError,
                          error.code == .canceledLogin {
                    continuation.resume(throwing: AuthError.cancelled)
                } else {
                    continuation.resume(throwing: AuthError.network(error?.localizedDescription ?? "cancelled"))
                }
            }
            session.presentationContextProvider = self
            session.prefersEphemeralWebBrowserSession = false
            // The system does not retain the session; keep it alive until done.
            webSession = session
            if !session.start(), once.claim() {
                continuation.resume(throwing: AuthError.server("Couldn't open the Google sign-in window."))
            }
        }
    }

    // MARK: Email + password

    func signIn(email: String, password: String) async {
        lastError = nil
        do {
            let response: SessionResponse = try await signInRequest(
                "auth/login",
                body: ["email": email.trimmingCharacters(in: .whitespacesAndNewlines), "password": password]
            )
            adopt(response)
        } catch let error as AuthError where error.status == 401 {
            lastError = "That email and password don't match. If you joined with Apple or Google, use that button instead."
        } catch {
            lastError = error.localizedDescription
        }
    }

    func register(email: String, password: String, name: String) async {
        lastError = nil
        do {
            let response: SessionResponse = try await signInRequest(
                "auth/register",
                body: [
                    "email": email.trimmingCharacters(in: .whitespacesAndNewlines),
                    "password": password,
                    "name": name.trimmingCharacters(in: .whitespacesAndNewlines),
                ]
            )
            adopt(response)
        } catch let error as AuthError where error.status == 409 {
            lastError = "An account with that email already exists. Sign in instead, or use Apple or Google with the same email."
        } catch {
            lastError = error.localizedDescription
        }
    }

    // MARK: Sign out

    func signOut() async {
        if let token {
            _ = try? await requestRaw("auth/logout", method: "POST", token: token, body: nil)
        }
        signOutLocally()
    }

    /// Permanently deletes the membership on the server, then clears local
    /// state. Throws (and keeps the session) if the server refused.
    func deleteAccount() async throws {
        guard let token else { throw AuthError.notSignedIn }
        _ = try await requestRaw("auth/account", method: "DELETE", token: token, body: nil)
        signOutLocally()
    }

    private func signOutLocally() {
        token = nil
        user = nil
        isOfflineSession = false
        Self.defaults.removeObject(forKey: Self.cachedUserKey)
    }

    private func adopt(_ response: SessionResponse) {
        // A fresh sign-in never inherits pre-account-scoping leftovers: they may
        // belong to whoever used this device before.
        Self.defaults.set(true, forKey: Self.accountScopedKey)
        token = response.token
        setUser(response.user)
        isOfflineSession = false
    }

    private func setUser(_ user: BatesAIUser) {
        self.user = user
        if let data = try? JSONEncoder().encode(user) {
            Self.defaults.set(data, forKey: Self.cachedUserKey)
        }
    }

    private static func loadCachedUser() -> BatesAIUser? {
        guard let data = defaults.data(forKey: cachedUserKey) else { return nil }
        return try? JSONDecoder().decode(BatesAIUser.self, from: data)
    }

    private func noteAccount(_ id: String?) {
        guard Self.lastAccountID != id else { return }
        if let id {
            Self.defaults.set(id, forKey: Self.lastAccountKey)
        } else {
            Self.defaults.removeObject(forKey: Self.lastAccountKey)
        }
        WorkoutSyncBridge.accountChanged(id)
    }

    /// Builds before account scoping kept the sync queue under global keys. The
    /// only safe owner for that queue is the member whose stored session is
    /// being restored, and only the first time this build runs.
    private func adoptLegacyStateIfNeeded(for userID: String) {
        guard !Self.defaults.bool(forKey: Self.accountScopedKey) else { return }
        Self.defaults.set(true, forKey: Self.accountScopedKey)
        GameProfileService.shared.adoptLegacyState(for: userID)
    }

    // MARK: Networking

    struct VerifyResponse: Decodable {
        let valid: Bool
        let user: BatesAIUser?
    }

    struct SessionResponse: Decodable {
        let token: String
        let user: BatesAIUser
    }

    private struct ServerError: Decodable {
        let error: String?
        let message: String?
        let retryAfter: Double?

        enum CodingKeys: String, CodingKey {
            case error, message
            case retryAfter = "retry_after"
        }
    }

    /// API URL for `path`, with query items assembled by URLComponents.
    /// `appendingPathComponent` percent-encodes "?" into the path, which turned
    /// "fitness/leaderboard?scope=…" into a 404 — so a "?" in `path` is split
    /// off here and merged with `query`.
    static func endpoint(_ path: String, query: [URLQueryItem] = []) -> URL {
        var pathPart = path
        var items: [URLQueryItem] = []
        if let mark = path.firstIndex(of: "?") {
            pathPart = String(path[..<mark])
            let rawQuery = String(path[path.index(after: mark)...])
            items = URLComponents(string: "?" + rawQuery)?.queryItems ?? []
        }
        items += query
        let base = apiBase.appendingPathComponent(pathPart)
        guard !items.isEmpty,
              var components = URLComponents(url: base, resolvingAgainstBaseURL: false)
        else { return base }
        components.queryItems = items
        // URLComponents leaves "+" alone, but the server decodes it as a space.
        components.percentEncodedQuery = components.percentEncodedQuery?
            .replacingOccurrences(of: "+", with: "%2B")
        return components.url ?? base
    }

    /// Performs a request and decodes the response. Non-2xx responses throw
    /// `AuthError.http` with the status and the server's own message.
    func request<T: Decodable>(
        _ path: String,
        method: String,
        token overrideToken: String? = nil,
        query: [URLQueryItem] = [],
        body: [String: Any]? = nil
    ) async throws -> T {
        let data = try await requestRaw(path, method: method, token: overrideToken ?? token, query: query, body: body)
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            #if DEBUG
            print("BatesAIAuth: could not decode \(T.self) from \(path): \(error)")
            #endif
            throw AuthError.server("Unexpected response from server.")
        }
    }

    /// Sign-in endpoints never carry a (possibly stale) bearer token.
    private func signInRequest<T: Decodable>(_ path: String, body: [String: Any]) async throws -> T {
        let data = try await requestRaw(path, method: "POST", token: nil, body: body)
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            throw AuthError.server("Unexpected response from server.")
        }
    }

    @discardableResult
    func requestRaw(
        _ path: String,
        method: String,
        token: String?,
        query: [URLQueryItem] = [],
        body: [String: Any]?
    ) async throws -> Data {
        var request = URLRequest(url: Self.endpoint(path, query: query))
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 30
        if let token {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        if let body {
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        }

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            throw AuthError.network(error.localizedDescription)
        }

        guard let http = response as? HTTPURLResponse else {
            throw AuthError.server("Malformed server response.")
        }
        guard (200..<300).contains(http.statusCode) else {
            let decoded = try? JSONDecoder().decode(ServerError.self, from: data)
            let raw = decoded?.error ?? decoded?.message
            // `error` is either a machine code ("rate_limited") or a sentence.
            let isCode = raw.map { $0.range(of: "^[a-z][a-z0-9_]*$", options: .regularExpression) != nil } ?? false
            let header = http.value(forHTTPHeaderField: "Retry-After").flatMap(Double.init)
            let retryAfter = (decoded?.retryAfter ?? header).map { Int($0.rounded(.up)) }
            let error = AuthError.http(
                status: http.statusCode,
                code: isCode ? raw : nil,
                message: isCode ? decoded?.message : raw,
                retryAfter: retryAfter
            )
            // The session was revoked elsewhere (signed out everywhere, account
            // deleted on the website): stop pretending to be signed in.
            if http.statusCode == 401, let token, token == self.token, path.hasPrefix("fitness/") {
                signOutLocally()
            }
            throw error
        }
        return data
    }

    // MARK: Nonce helpers

    private static func randomNonce(length: Int = 32) -> String {
        let charset = Array("0123456789ABCDEFGHIJKLMNOPQRSTUVXYZabcdefghijklmnopqrstuvwxyz-._")
        var result = ""
        var remaining = length
        while remaining > 0 {
            var random: UInt8 = 0
            let status = SecRandomCopyBytes(kSecRandomDefault, 1, &random)
            guard status == errSecSuccess else { continue }
            // Reject values that would bias the modulo, then map into the charset.
            if random < charset.count {
                result.append(charset[Int(random)])
                remaining -= 1
            }
        }
        return result
    }

    private static func sha256(_ input: String) -> String {
        SHA256.hash(data: Data(input.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }
}

/// Guards a continuation that two callbacks might both try to resume.
private final class ResumeOnce: @unchecked Sendable {
    private let lock = NSLock()
    private var claimed = false

    func claim() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if claimed { return false }
        claimed = true
        return true
    }
}

// MARK: - AuthenticationServices presentation

extension BatesAIAuth: ASWebAuthenticationPresentationContextProviding {
    nonisolated func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        Self.anchor()
    }

    /// AuthenticationServices always calls the presentation-anchor callback on
    /// the main thread, but declares it nonisolated, so assume the isolation
    /// rather than hopping (the framework needs the window synchronously).
    private nonisolated static func anchor() -> ASPresentationAnchor {
        MainActor.assumeIsolated {
            #if os(macOS)
            return NSApplication.shared.windows.first { $0.isKeyWindow }
                ?? NSApplication.shared.windows.first
                ?? ASPresentationAnchor()
            #else
            let scene = UIApplication.shared.connectedScenes
                .compactMap { $0 as? UIWindowScene }
                .first { $0.activationState == .foregroundActive }
            return scene?.keyWindow ?? ASPresentationAnchor()
            #endif
        }
    }
}

#if os(macOS)
import AppKit
#else
import UIKit
#endif
