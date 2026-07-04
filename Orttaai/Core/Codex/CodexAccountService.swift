// CodexAccountService.swift
// Orttaai

import AppKit
import Combine
import Foundation

/// Rate-limit summary for the Settings usage meter. Windows come from
/// `account/rateLimits/read`: primary is the short window (~5 h), secondary
/// the long one (~weekly).
struct CodexRateLimitSnapshot: Equatable, Sendable {
    struct Window: Equatable, Sendable {
        let usedPercent: Int
        let windowDurationMins: Int?
        let resetsAt: Date?
    }

    let primary: Window?
    let secondary: Window?
}

/// Auth and subscription state for the ChatGPT (Codex) provider.
///
/// Codex owns the entire credential lifecycle: `signIn()` just asks the
/// app-server to run its browser OAuth flow, and tokens live in
/// `~/.codex/auth.json` managed by the CLI — Orttaai never sees or stores a
/// secret. The feature is gated on `account.type == "chatgpt"`; any
/// `planType` string is accepted (plan names drift: "plus", "pro",
/// "prolite", "business", …).
@MainActor
final class CodexAccountService: ObservableObject {
    enum AccountState: Equatable {
        case unknown
        case codexNotInstalled
        case codexOutdated(found: String)
        case signedOut
        /// Codex is authenticated with an OpenAI API key, which doesn't carry
        /// a ChatGPT subscription; the user must sign in with ChatGPT.
        case apiKeyOnly
        case signedIn(email: String?, planType: String?)

        var isUsable: Bool {
            if case .signedIn = self { return true }
            return false
        }
    }

    @Published private(set) var state: AccountState = .unknown
    @Published private(set) var rateLimits: CodexRateLimitSnapshot?
    @Published private(set) var isSigningIn = false
    @Published private(set) var isRefreshing = false
    @Published private(set) var lastErrorMessage: String?

    private let connection: CodexAppServerConnection
    private var signInTask: Task<Void, Never>?
    private static let signInTimeout: TimeInterval = 300

    init(connection: CodexAppServerConnection = .shared) {
        self.connection = connection
    }

    // MARK: - State

    func refresh() async {
        isRefreshing = true
        lastErrorMessage = nil
        defer { isRefreshing = false }

        guard let info = await connection.detectBinary() else {
            state = .codexNotInstalled
            rateLimits = nil
            return
        }
        guard CodexBinaryLocator.isVersionSupported(info.version) else {
            state = .codexOutdated(found: info.version)
            rateLimits = nil
            return
        }

        do {
            let result = try await connection.request(
                method: "account/read",
                params: ["refreshToken": false]
            )
            state = Self.accountState(fromReadResult: result)
            if state.isUsable {
                await refreshRateLimits()
            } else {
                rateLimits = nil
            }
        } catch {
            state = .signedOut
            rateLimits = nil
            lastErrorMessage = error.localizedDescription
        }
    }

    func refreshRateLimits() async {
        guard let result = try? await connection.request(method: "account/rateLimits/read") else {
            return
        }
        rateLimits = Self.rateLimitSnapshot(fromReadResult: result)
    }

    // MARK: - Sign in / out

    /// Starts the managed ChatGPT browser login. The app-server hosts the
    /// OAuth callback itself; we open the URL and wait for
    /// `account/login/completed`.
    func signIn() {
        guard !isSigningIn else { return }
        isSigningIn = true
        lastErrorMessage = nil

        signInTask = Task { [connection] in
            defer { self.isSigningIn = false }
            do {
                let notifications = try await connection.notifications()
                let result = try await connection.request(
                    method: "account/login/start",
                    params: ["type": "chatgpt"]
                )
                let loginID = result["loginId"] as? String
                guard let authURLString = result["authUrl"] as? String,
                      let authURL = URL(string: authURLString) else {
                    throw CodexError.invalidResponse
                }
                NSWorkspace.shared.open(authURL)

                let completed = try await Self.awaitLoginCompletion(
                    notifications: notifications,
                    loginID: loginID,
                    timeout: Self.signInTimeout
                )
                if !completed.success {
                    if let loginID {
                        _ = try? await connection.request(
                            method: "account/login/cancel",
                            params: ["loginId": loginID]
                        )
                    }
                    self.lastErrorMessage = completed.errorMessage ?? "Sign-in was not completed."
                }
            } catch {
                self.lastErrorMessage = error.localizedDescription
            }
            await self.refresh()
        }
    }

    func cancelSignIn() {
        signInTask?.cancel()
        signInTask = nil
        isSigningIn = false
    }

    func signOut() async {
        lastErrorMessage = nil
        do {
            _ = try await connection.request(method: "account/logout")
        } catch {
            lastErrorMessage = error.localizedDescription
        }
        await refresh()
    }

    // MARK: - Parsing (static for testability)

    nonisolated static func accountState(fromReadResult result: [String: Any]) -> AccountState {
        guard let account = result["account"] as? [String: Any],
              let type = account["type"] as? String else {
            return .signedOut
        }
        switch type {
        case "chatgpt", "chatgptAuthTokens":
            return .signedIn(
                email: account["email"] as? String,
                planType: account["planType"] as? String
            )
        case "apiKey":
            return .apiKeyOnly
        default:
            // Unknown auth mode (Bedrock, agent identity, future modes):
            // no ChatGPT subscription attached, treat as needing sign-in.
            return .apiKeyOnly
        }
    }

    nonisolated static func rateLimitSnapshot(fromReadResult result: [String: Any]) -> CodexRateLimitSnapshot? {
        guard let rateLimits = result["rateLimits"] as? [String: Any] else { return nil }
        func window(_ object: Any?) -> CodexRateLimitSnapshot.Window? {
            guard let dictionary = object as? [String: Any],
                  let usedPercent = (dictionary["usedPercent"] as? NSNumber)?.intValue else {
                return nil
            }
            let resetsAt = (dictionary["resetsAt"] as? NSNumber)
                .map { Date(timeIntervalSince1970: $0.doubleValue) }
            return CodexRateLimitSnapshot.Window(
                usedPercent: usedPercent,
                windowDurationMins: (dictionary["windowDurationMins"] as? NSNumber)?.intValue,
                resetsAt: resetsAt
            )
        }
        return CodexRateLimitSnapshot(
            primary: window(rateLimits["primary"]),
            secondary: window(rateLimits["secondary"])
        )
    }

    private struct LoginCompletion {
        let success: Bool
        let errorMessage: String?
    }

    private nonisolated static func awaitLoginCompletion(
        notifications: AsyncStream<CodexServerNotification>,
        loginID: String?,
        timeout: TimeInterval
    ) async throws -> LoginCompletion {
        try await withThrowingTaskGroup(of: LoginCompletion.self) { group in
            group.addTask {
                for await notification in notifications {
                    guard notification.method == "account/login/completed" else { continue }
                    if let loginID,
                       let notifiedID = notification.params["loginId"] as? String,
                       notifiedID != loginID {
                        continue
                    }
                    return LoginCompletion(
                        success: (notification.params["success"] as? Bool) ?? false,
                        errorMessage: notification.params["error"] as? String
                    )
                }
                return LoginCompletion(success: false, errorMessage: "The Codex app server stopped during sign-in.")
            }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                return LoginCompletion(success: false, errorMessage: "Sign-in timed out. Complete the browser flow and try again.")
            }
            defer { group.cancelAll() }
            guard let first = try await group.next() else {
                return LoginCompletion(success: false, errorMessage: nil)
            }
            return first
        }
    }
}
