import AuthenticationServices
import CryptoKit
import Foundation
import Observation
import Supabase
import os

struct AuthUser: Equatable, Sendable {
    var id: String
    var email: String
    var displayName: String
    var avatarUrl: String?
    /// Signed in only through a social provider (Google / Apple) and no password set yet — drives the
    /// "Set password" affordance in Settings.
    var isSocialOnly: Bool
    var providers: [String]
}

enum AuthState: Equatable, Sendable {
    case loading
    case signedOut
    case signedIn(AuthUser)
}

enum SignInResult: Equatable, Sendable {
    case success
    case cancelled
    case emailConfirmationRequired
    case emailNotConfirmed
    case invalidCredentials
    case captchaFailed
    case emailAlreadyRegistered
    case passwordAlreadySet
    case weakPassword
    case tooManyRequests
    case error(String)
}

/// Account layer over Supabase Auth. **Not a login wall** — logged-out users browse freely; write
/// features check `isSignedIn` and call `requestSignIn()` to raise the login sheet on demand.
@MainActor
@Observable
final class AuthService {
    static let shared = AuthService()

    private(set) var state: AuthState = .loading
    /// The on-demand login sheet trigger (Android's SignInController).
    var showLogin = false

    /// Fired after a session appears (sign-in or cold-start restore) / disappears.
    @ObservationIgnored var onSignedIn: ((AuthUser) -> Void)?

    @ObservationIgnored private var passwordChecked = Set<String>()
    @ObservationIgnored private var listener: Task<Void, Never>?
    private let client = SupabaseProvider.client
    private let log = Logger(subsystem: "com.senniapp.brickwares", category: "Auth")

    var user: AuthUser? { if case .signedIn(let u) = state { u } else { nil } }
    var isSignedIn: Bool { user != nil }
    var isLoading: Bool { state == .loading }

    private init() {}

    /// Start observing the session. The SDK restores + auto-refreshes the Keychain session and emits
    /// `.initialSession` first, so the splash can hold until the state leaves `.loading`.
    func start() {
        guard listener == nil else { return }
        guard AppConfig.isConfigured else { state = .signedOut; return }
        listener = Task { [weak self] in
            guard let self else { return }
            for await (event, session) in client.auth.authStateChanges {
                switch event {
                case .initialSession, .signedIn, .tokenRefreshed, .userUpdated:
                    apply(session?.user)
                case .signedOut, .userDeleted:
                    apply(nil)
                default:
                    break
                }
            }
        }
    }

    func requestSignIn() { showLogin = true }

    private func apply(_ user: User?) {
        guard let user else {
            if state != .signedOut { state = .signedOut }
            return
        }
        let mapped = map(user)
        let wasSignedIn = self.user?.id == mapped.id
        if state != .signedIn(mapped) { state = .signedIn(mapped) }
        if !wasSignedIn {
            if showLogin { showLogin = false }
            onSignedIn?(mapped)
        }
        if mapped.isSocialOnly { Task { await checkPasswordOnServer(userId: mapped.id) } }
    }

    private func map(_ user: User) -> AuthUser {
        func meta(_ key: String) -> String? { user.userMetadata[key]?.stringValue?.nilIfBlank }
        let email = user.email ?? ""
        var providers = (user.identities ?? []).map(\.provider)
        if providers.isEmpty, let list = user.appMetadata["providers"]?.arrayValue {
            providers = list.compactMap(\.stringValue)
        }
        let social = providers.contains("google") || providers.contains("apple")
        let name = meta("full_name") ?? meta("name")
            ?? email.split(separator: "@").first.map(String.init)?.nilIfBlank
            ?? "BrickWares user"
        return AuthUser(
            id: user.id.uuidString.lowercased(),
            email: email,
            displayName: name,
            avatarUrl: meta("avatar_url") ?? meta("picture"),
            isSocialOnly: social && !providers.contains("email") && !AccountPrefs.hasPassword(user.id.uuidString.lowercased()),
            providers: providers
        )
    }

    // MARK: Email + password

    func signIn(email: String, password: String, captchaToken: String?) async -> SignInResult {
        await attempt { try await self.client.auth.signIn(email: email, password: password, captchaToken: captchaToken) }
    }

    /// `lang` is stamped into user metadata so the confirmation email renders in en/vi.
    func signUp(email: String, password: String, lang: String, captchaToken: String?) async -> SignInResult {
        do {
            let response = try await client.auth.signUp(
                email: email, password: password, data: ["lang": .string(lang)], captchaToken: captchaToken
            )
            // A session right away means auto-confirm (local stack); otherwise the OTP step follows.
            return response.session != nil ? .success : .emailConfirmationRequired
        } catch {
            return Self.mapError(error)
        }
    }

    func verifySignUpCode(email: String, code: String) async -> SignInResult {
        await attempt { try await self.client.auth.verifyOTP(email: email, token: code, type: .signup) }
    }

    func resendSignUpCode(email: String, captchaToken: String?) async -> SignInResult {
        await attempt { try await self.client.auth.resend(email: email, type: .signup, captchaToken: captchaToken) }
    }

    func sendPasswordReset(email: String, captchaToken: String?) async -> SignInResult {
        await attempt { try await self.client.auth.resetPasswordForEmail(email, captchaToken: captchaToken) }
    }

    /// Adds an email credential to a social-only account (or changes the password). Needs a live session.
    func setPassword(_ password: String) async -> SignInResult {
        do {
            try await client.auth.update(user: UserAttributes(password: password))
            markPasswordSet()
            return .success
        } catch {
            let mapped = Self.mapError(error)
            if mapped == .passwordAlreadySet { markPasswordSet() }
            return mapped
        }
    }

    // MARK: Social

    /// Sign in with Apple. `idToken` comes from `ASAuthorizationAppleIDCredential`; `rawNonce` is the
    /// un-hashed nonce whose SHA-256 was put on the request (see `Nonce`).
    func signInWithApple(idToken: String, rawNonce: String, fullName: PersonNameComponents?) async -> SignInResult {
        do {
            try await client.auth.signInWithIdToken(
                credentials: .init(provider: .apple, idToken: idToken, nonce: rawNonce)
            )
            // Apple only returns the name on the FIRST authorization, and never inside the ID token —
            // persist it to user metadata so the account has a display name.
            if let fullName, let name = PersonNameComponentsFormatter().string(from: fullName).nilIfBlank {
                _ = try? await client.auth.update(user: UserAttributes(data: ["full_name": .string(name)]))
            }
            return .success
        } catch {
            return Self.mapError(error)
        }
    }

    /// Google via Supabase's OAuth web flow in an `ASWebAuthenticationSession` (system sheet, no extra
    /// SDK). The redirect URL must be allow-listed in the Supabase dashboard.
    func signInWithGoogle() async -> SignInResult {
        do {
            try await client.auth.signInWithOAuth(provider: .google, redirectTo: AppConfig.oauthRedirectURL) { session in
                session.prefersEphemeralWebBrowserSession = false
            }
            return .success
        } catch let error as ASWebAuthenticationSessionError where error.code == .canceledLogin {
            return .cancelled
        } catch {
            return Self.mapError(error)
        }
    }

    // MARK: Sign-out / deletion

    /// Clears the on-device session only (no network call), so it works offline.
    func signOut() async {
        try? await client.auth.signOut(scope: .local)
    }

    /// Deletes the account server-side (cascades all user data). The caller wipes local stores first
    /// via `onAccountDeleted`, then the local session is dropped.
    func deleteAccount(wipeLocal: () async -> Void) async -> Bool {
        do {
            try await client.rpc("delete_current_user").execute()
        } catch {
            log.error("delete_current_user failed: \(error.localizedDescription)")
            return false
        }
        await wipeLocal()
        await signOut()
        return true
    }

    // MARK: has-password

    /// Supabase's user object doesn't expose whether a password exists, so ask once per user per
    /// process; a `true` answer is remembered on-device and flips `isSocialOnly` off.
    private func checkPasswordOnServer(userId: String) async {
        guard passwordChecked.insert(userId).inserted else { return }
        do {
            let has: Bool = try await client.rpc("has_password").execute().value
            if has { markPasswordSet() }
        } catch {
            passwordChecked.remove(userId) // allow a retry
        }
    }

    private func markPasswordSet() {
        guard let id = user?.id else { return }
        AccountPrefs.setHasPassword(id)
        if let current = client.auth.currentUser { apply(current) }
    }

    // MARK: Error mapping

    private func attempt(_ body: @escaping () async throws -> some Any) async -> SignInResult {
        do { _ = try await body(); return .success } catch { return Self.mapError(error) }
    }

    private static func mapError(_ error: Error) -> SignInResult {
        if error is CancellationError { return .cancelled }
        if let auth = error as? AuthError {
            switch auth.errorCode {
            case .emailNotConfirmed: return .emailNotConfirmed
            case .invalidCredentials: return .invalidCredentials
            case .captchaFailed: return .captchaFailed
            case .emailExists, .userAlreadyExists: return .emailAlreadyRegistered
            case .samePassword: return .passwordAlreadySet
            case .weakPassword: return .weakPassword
            case .overRequestRateLimit, .overEmailSendRateLimit: return .tooManyRequests
            default: break
            }
            if case .weakPassword = auth { return .weakPassword }
            return .error(auth.message)
        }
        return .error(error.localizedDescription)
    }
}

/// Device-local per-account fact (which user ids have a password) that the Supabase user object
/// doesn't expose. Not synced.
enum AccountPrefs {
    private static let key = "account.has_password_ids"

    static func hasPassword(_ userId: String) -> Bool {
        (UserDefaults.standard.stringArray(forKey: key) ?? []).contains(userId)
    }

    static func setHasPassword(_ userId: String) {
        var ids = Set(UserDefaults.standard.stringArray(forKey: key) ?? [])
        ids.insert(userId)
        UserDefaults.standard.set(Array(ids), forKey: key)
    }
}

/// OIDC nonce: the SHA-256 hex goes on the provider request, the raw value goes to Supabase, which
/// re-hashes and compares it to the token claim (replay protection; prod enforces it).
struct Nonce: Sendable {
    let raw: String
    var sha256: String { SHA256.hash(data: Data(raw.utf8)).map { String(format: "%02x", $0) }.joined() }

    init() { raw = UUID().uuidString + UUID().uuidString }
}
