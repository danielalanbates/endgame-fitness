//
//  BatesAIAuth.swift
//  Endgame Fitness
//
//  Sign-in against the batesai.org membership system.
//
//  Two routes, both ending in a BatesAI session token:
//    • Sign in with Apple — native, via AuthenticationServices. The device hands
//      us an identity token signed by Apple; the server verifies it against
//      Apple's JWKS and returns our own token. Required by App Store review
//      whenever a third-party login is offered.
//    • Google — via ASWebAuthenticationSession, so there is no third-party SDK
//      to vendor and no client secret on the device.
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

    var isPremium: Bool { membership == "premium" }
}

enum AuthError: LocalizedError {
    case cancelled
    case missingIdentityToken
    case server(String)
    case network(String)
    case notSignedIn

    var errorDescription: String? {
        switch self {
        case .cancelled:             return "Sign-in was cancelled."
        case .missingIdentityToken:  return "Apple did not return an identity token. Please try again."
        case .server(let message):   return message
        case .network(let message):  return "Network error: \(message)"
        case .notSignedIn:           return "You are not signed in."
        }
    }
}

// MARK: - Keychain

/// Minimal Keychain wrapper for the one secret this app stores.
enum TokenStore {
    private static let service = "org.batesai.endgamefitness"
    private static let account = "session-token"

    static func save(_ token: String) {
        let data = Data(token.utf8)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        // Delete-then-add is the reliable way to overwrite; SecItemUpdate fails
        // when no item exists yet.
        SecItemDelete(query as CFDictionary)

        var attributes = query
        attributes[kSecValueData as String] = data
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        SecItemAdd(attributes as CFDictionary, nil)
    }

    static func load() -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data,
              let token = String(data: data, encoding: .utf8)
        else { return nil }
        return token
    }

    static func clear() {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
    }
}

// MARK: - Auth service

@MainActor
final class BatesAIAuth: NSObject, ObservableObject {
    static let shared = BatesAIAuth()

    @Published private(set) var user: BatesAIUser?
    @Published private(set) var isRestoring = true
    @Published var lastError: String?

    /// True once we hold a token the server has confirmed.
    var isSignedIn: Bool { user != nil }

    private(set) var token: String? {
        didSet {
            if let token { TokenStore.save(token) } else { TokenStore.clear() }
        }
    }

    static let apiBase = URL(string: "https://batesai.org/api")!

    /// Nonce for the in-flight Apple request. Apple echoes its SHA-256 back
    /// inside the identity token, which is what stops a captured token from
    /// being replayed against our server.
    private var currentNonce: String?
    private var appleContinuation: CheckedContinuation<ASAuthorization, Error>?

    private override init() {
        super.init()
        self.token = TokenStore.load()
    }

    // MARK: Session restore

    /// Called once at launch. Confirms a stored token is still valid.
    func restoreSession() async {
        defer { isRestoring = false }
        guard let token else { return }

        do {
            let response: VerifyResponse = try await request(
                "auth/verify", method: "GET", token: token
            )
            if response.valid, let user = response.user {
                self.user = user
            } else {
                signOutLocally()
            }
        } catch AuthError.server {
            // A rejected token is terminal — clear it rather than looping.
            signOutLocally()
        } catch {
            // Network failure: keep the token so the app still works offline and
            // retries on the next launch.
            self.lastError = error.localizedDescription
        }
    }

    // MARK: Sign in with Apple

    func signInWithApple() async {
        lastError = nil
        do {
            let nonce = Self.randomNonce()
            currentNonce = nonce

            let provider = ASAuthorizationAppleIDProvider()
            let appleRequest = provider.createRequest()
            appleRequest.requestedScopes = [.fullName, .email]
            appleRequest.nonce = Self.sha256(nonce)

            let authorization = try await performAppleRequest(appleRequest)

            guard
                let credential = authorization.credential as? ASAuthorizationAppleIDCredential,
                let tokenData = credential.identityToken,
                let identityToken = String(data: tokenData, encoding: .utf8)
            else { throw AuthError.missingIdentityToken }

            // Apple sends the user's name only on the very first authorization,
            // so forward it now or it is lost forever.
            var fullName: [String: String]?
            if let components = credential.fullName {
                let given = components.givenName ?? ""
                let family = components.familyName ?? ""
                if !(given.isEmpty && family.isEmpty) {
                    fullName = ["givenName": given, "familyName": family]
                }
            }

            var body: [String: Any] = ["identity_token": identityToken, "nonce": nonce]
            if let fullName { body["full_name"] = fullName }

            let response: SessionResponse = try await request(
                "auth/native/apple", method: "POST", body: body
            )
            adopt(response)
        } catch is CancellationError {
            lastError = nil
        } catch let error as ASAuthorizationError where error.code == .canceled {
            lastError = nil
        } catch {
            lastError = error.localizedDescription
        }
        currentNonce = nil
    }

    private func performAppleRequest(_ request: ASAuthorizationAppleIDRequest) async throws -> ASAuthorization {
        try await withCheckedThrowingContinuation { continuation in
            self.appleContinuation = continuation
            let controller = ASAuthorizationController(authorizationRequests: [request])
            controller.delegate = self
            controller.presentationContextProvider = self
            controller.performRequests()
        }
    }

    // MARK: Sign in with Google

    /// Uses the system browser via ASWebAuthenticationSession. The server holds
    /// the client secret and does the code exchange, so nothing sensitive ships
    /// inside the app binary.
    func signInWithGoogle() async {
        lastError = nil
        let callbackScheme = "endgamefitness"
        guard var components = URLComponents(
            url: Self.apiBase.appendingPathComponent("auth/oauth/google"),
            resolvingAgainstBaseURL: false
        ) else { return }
        components.queryItems = [URLQueryItem(name: "redirect_scheme", value: callbackScheme)]
        guard let url = components.url else { return }

        do {
            let callbackURL = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<URL, Error>) in
                let session = ASWebAuthenticationSession(
                    url: url, callbackURLScheme: callbackScheme
                ) { callback, error in
                    if let callback {
                        continuation.resume(returning: callback)
                    } else if let error = error as? ASWebAuthenticationSessionError,
                              error.code == .canceledLogin {
                        continuation.resume(throwing: AuthError.cancelled)
                    } else {
                        continuation.resume(throwing: error ?? AuthError.cancelled)
                    }
                }
                session.presentationContextProvider = self
                session.prefersEphemeralWebBrowserSession = false
                session.start()
            }

            let items = URLComponents(url: callbackURL, resolvingAgainstBaseURL: false)?.queryItems
            guard let sessionToken = items?.first(where: { $0.name == "token" })?.value else {
                throw AuthError.server("Google sign-in did not return a session.")
            }

            self.token = sessionToken
            let verify: VerifyResponse = try await request("auth/verify", method: "GET", token: sessionToken)
            guard verify.valid, let user = verify.user else {
                throw AuthError.server("Session could not be verified.")
            }
            self.user = user
        } catch AuthError.cancelled {
            lastError = nil
        } catch {
            lastError = error.localizedDescription
        }
    }

    // MARK: Email + password

    func signIn(email: String, password: String) async {
        lastError = nil
        do {
            let response: SessionResponse = try await request(
                "auth/login", method: "POST",
                body: ["email": email, "password": password]
            )
            adopt(response)
        } catch {
            lastError = error.localizedDescription
        }
    }

    func register(email: String, password: String, name: String) async {
        lastError = nil
        do {
            let response: SessionResponse = try await request(
                "auth/register", method: "POST",
                body: ["email": email, "password": password, "name": name]
            )
            adopt(response)
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

    private func signOutLocally() {
        token = nil
        user = nil
    }

    private func adopt(_ response: SessionResponse) {
        token = response.token
        user = response.user
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

    private struct ServerError: Decodable { let error: String }

    /// Performs a request and decodes the response, mapping non-2xx bodies to
    /// `AuthError.server` with the server's own message where one exists.
    func request<T: Decodable>(
        _ path: String,
        method: String,
        token overrideToken: String? = nil,
        body: [String: Any]? = nil
    ) async throws -> T {
        let data = try await requestRaw(path, method: method, token: overrideToken ?? token, body: body)
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
        body: [String: Any]?
    ) async throws -> Data {
        var request = URLRequest(url: Self.apiBase.appendingPathComponent(path))
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
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
            let message = (try? JSONDecoder().decode(ServerError.self, from: data))?.error
                ?? "Server returned \(http.statusCode)."
            throw AuthError.server(message)
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

// MARK: - AuthenticationServices delegates

extension BatesAIAuth: ASAuthorizationControllerDelegate {
    nonisolated func authorizationController(
        controller: ASAuthorizationController,
        didCompleteWithAuthorization authorization: ASAuthorization
    ) {
        Task { @MainActor in
            appleContinuation?.resume(returning: authorization)
            appleContinuation = nil
        }
    }

    nonisolated func authorizationController(
        controller: ASAuthorizationController,
        didCompleteWithError error: Error
    ) {
        Task { @MainActor in
            appleContinuation?.resume(throwing: error)
            appleContinuation = nil
        }
    }
}

extension BatesAIAuth: ASAuthorizationControllerPresentationContextProviding,
                       ASWebAuthenticationPresentationContextProviding {
    nonisolated func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        Self.anchor()
    }

    nonisolated func presentationAnchor(for controller: ASAuthorizationController) -> ASPresentationAnchor {
        Self.anchor()
    }

    /// AuthenticationServices always calls the presentation-anchor callbacks on
    /// the main thread, but declares them nonisolated, so assume the isolation
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
