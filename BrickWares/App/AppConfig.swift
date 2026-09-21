import Foundation

/// Build-time configuration. None of these are secrets — they all ship inside the app binary and RLS
/// is the security layer — but the Supabase publishable key is per-environment, so it is read from a
/// bundled `Secrets.plist` (gitignored; copy `Secrets.example.plist`) rather than committed in source.
enum AppConfig {
    /// Hosted Supabase project (same backend as the Android `prod` flavor).
    static let defaultSupabaseURL = "https://thntvdpsixepidwvrxxj.supabase.co"

    /// Google "Web" OAuth client id — the ID-token audience Supabase validates (shared with Android).
    static let googleWebClientID = "1057688172135-4273me46h3nepbgc9qgt3onul3k55k4r.apps.googleusercontent.com"

    /// Cloudflare Turnstile SITE key (public). Blank disables the in-app captcha gate (local dev).
    static let defaultTurnstileSiteKey = "0x4AAAAAAE4T5dPOi1S4zDrZ"

    /// The app's own page hosting the Turnstile widget (loaded in a hidden WKWebView).
    static let captchaPageURL = URL(string: "https://brickwares.app/captcha")!
    static let captchaAllowedHosts: Set<String> = ["brickwares.app", "www.brickwares.app", "challenges.cloudflare.com"]

    static let privacyURL = URL(string: "https://brickwares.app/privacy-policy")!
    static let termsURL = URL(string: "https://brickwares.app/terms-of-service")!

    /// OAuth redirect for the Google web flow. Must be in Supabase → Auth → URL Configuration → Redirect URLs.
    static let oauthCallbackScheme = "brickwares"
    static let oauthRedirectURL = URL(string: "brickwares://auth-callback")!

    private static let secrets: [String: Any] = {
        guard let url = Bundle.main.url(forResource: "Secrets", withExtension: "plist"),
              let data = try? Data(contentsOf: url),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        else { return [:] }
        return plist
    }()

    private static func secret(_ key: String) -> String? {
        (secrets[key] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
    }

    static var supabaseURL: URL {
        URL(string: secret("SUPABASE_URL") ?? defaultSupabaseURL) ?? URL(string: defaultSupabaseURL)!
    }

    /// Empty when `Secrets.plist` is missing — every Supabase request then fails with
    /// "No API key found in request", so the root view shows a configuration notice instead.
    static var supabaseAnonKey: String { secret("SUPABASE_ANON_KEY") ?? "" }

    static var isConfigured: Bool { !supabaseAnonKey.isEmpty }

    /// `TURNSTILE_SITE_KEY` in Secrets.plist overrides (set it to an empty string to disable the gate
    /// against a local stack; Cloudflare test keys also work).
    static var turnstileSiteKey: String {
        if let raw = secrets["TURNSTILE_SITE_KEY"] as? String { return raw.trimmingCharacters(in: .whitespaces) }
        return defaultTurnstileSiteKey
    }

    static var appVersion: String {
        let v = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        let b = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?"
        return "\(v) (\(b))"
    }
}

extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
    var nilIfBlank: String? { trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : self }
}
