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

    // MARK: - Local dev (the `BrickWares Dev` scheme / `Dev` build configuration)

    /// True in the `Dev` build configuration (bundle id `…​.dev`, name "BrickWares Dev"), which points
    /// at a LOCAL Supabase stack (CLI + Docker) instead of prod — the iOS analog of the Android `dev`
    /// flavor. Defined by `SWIFT_ACTIVE_COMPILATION_CONDITIONS = DEV_LOCAL` on that configuration.
    static let isDevLocal: Bool = {
        #if DEV_LOCAL
        return true
        #else
        return false
        #endif
    }()

    /// Local Supabase URL for the Dev build. The iOS Simulator reaches the Mac host directly at
    /// 127.0.0.1 (there is no `10.0.2.2` alias like the Android emulator). For a PHYSICAL device on the
    /// same Wi-Fi, set `BRICKWARES_DEV_SUPABASE_URL=http://<mac-LAN-IP>:54321` in the scheme's
    /// environment (the phone can't reach the Mac's 127.0.0.1); the local stack must bind 0.0.0.0
    /// (`[api] host` in `supabase/config.toml`) and the Mac firewall must allow TCP 54321.
    static let devSupabaseURLDefault = "http://127.0.0.1:54321"

    /// The well-known LOCAL Supabase publishable key printed by `supabase start` — identical on every
    /// machine, NOT a secret. Same value the Android `dev` flavor hardcodes.
    static let devSupabaseAnonKey = "sb_publishable_ACJWlzQHlZjBrEguHvfOxg_3BJgxAaH"

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
        #if DEV_LOCAL
        let raw = ProcessInfo.processInfo.environment["BRICKWARES_DEV_SUPABASE_URL"]?.nilIfBlank ?? devSupabaseURLDefault
        return URL(string: raw) ?? URL(string: devSupabaseURLDefault)!
        #else
        return URL(string: secret("SUPABASE_URL") ?? defaultSupabaseURL) ?? URL(string: defaultSupabaseURL)!
        #endif
    }

    /// In prod, empty when `Secrets.plist` is missing — every Supabase request then fails with
    /// "No API key found in request", so the root view shows a configuration notice instead. In the
    /// Dev build it is the hardcoded local publishable key, so `isConfigured` is always true.
    static var supabaseAnonKey: String {
        #if DEV_LOCAL
        return devSupabaseAnonKey
        #else
        return secret("SUPABASE_ANON_KEY") ?? ""
        #endif
    }

    static var isConfigured: Bool { !supabaseAnonKey.isEmpty }

    /// Prod: `TURNSTILE_SITE_KEY` in Secrets.plist overrides the default (an empty string disables the
    /// gate; Cloudflare test keys also work). Dev: always blank — the local GoTrue has captcha off, so
    /// `CaptchaGate.acquire()` returns `.disabled` and the email flows send no token.
    static var turnstileSiteKey: String {
        #if DEV_LOCAL
        return ""
        #else
        if let raw = secrets["TURNSTILE_SITE_KEY"] as? String { return raw.trimmingCharacters(in: .whitespaces) }
        return defaultTurnstileSiteKey
        #endif
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
