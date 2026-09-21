import Foundation
import Supabase

/// Single app-wide Supabase client. The Auth module persists + auto-refreshes the session in the
/// Keychain, so a returning user is restored without any code here.
enum SupabaseProvider {
    static let client: SupabaseClient = {
        SupabaseClient(
            supabaseURL: AppConfig.supabaseURL,
            supabaseKey: AppConfig.supabaseAnonKey,
            options: SupabaseClientOptions(
                auth: .init(redirectToURL: AppConfig.oauthRedirectURL, flowType: .pkce),
                global: .init(session: apiSession)
            )
        )
    }()

    /// API traffic uses an **ephemeral** configuration: no on-disk HTTP cache (API responses must
    /// never be served stale) and — just as important — no persisted `alt-svc` memory. Supabase sits
    /// behind Cloudflare, which advertises HTTP/3; with the default configuration URLSession remembers
    /// that across launches and opens later connections over QUIC, which hangs until timeout wherever
    /// QUIC is broken (the iOS 18.4 Simulator, some VPNs / UDP-filtering networks). Verified
    /// 2026-09-21: same request, `.shared` timed out while an ephemeral session answered in 0.4 s.
    /// The auth session itself lives in the Keychain, so this does not affect staying signed in.
    static let apiSession: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 20
        config.waitsForConnectivity = false
        return URLSession(configuration: config)
    }()
}

/// A calendar day without time or zone — the Swift stand-in for `java.time.LocalDate`. Catalog dates
/// are plain `yyyy-MM-dd` strings, so comparing components avoids any timezone drift.
struct LocalDay: Comparable, Hashable, Sendable {
    var year: Int
    var month: Int
    var day: Int

    /// Tolerant parse: takes the first 10 chars, nil on anything that isn't `yyyy-MM-dd`.
    init?(_ s: String?) {
        guard let s, s.count >= 10 else { return nil }
        let parts = s.prefix(10).split(separator: "-")
        guard parts.count == 3, let y = Int(parts[0]), let m = Int(parts[1]), let d = Int(parts[2]),
              (1...12).contains(m), (1...31).contains(d)
        else { return nil }
        year = y; month = m; day = d
    }

    init(date: Date = Date(), calendar: Calendar = .current) {
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        year = c.year ?? 1970; month = c.month ?? 1; day = c.day ?? 1
    }

    static var today: LocalDay { LocalDay() }

    var iso: String { String(format: "%04d-%02d-%02d", year, month, day) }

    static func < (a: LocalDay, b: LocalDay) -> Bool {
        (a.year, a.month, a.day) < (b.year, b.month, b.day)
    }
}

/// Runs `operation` with a deadline; throws `TimeoutError` when it overruns (the `withTimeout` analog).
struct TimeoutError: LocalizedError {
    var errorDescription: String? { "The request timed out." }
}

func withTimeout<T: Sendable>(
    seconds: Double, _ operation: @escaping @Sendable () async throws -> T
) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask { try await operation() }
        group.addTask {
            try await Task.sleep(for: .seconds(seconds))
            throw TimeoutError()
        }
        defer { group.cancelAll() }
        guard let first = try await group.next() else { throw TimeoutError() }
        return first
    }
}
