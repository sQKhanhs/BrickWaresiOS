import Foundation
import os

/// FX between the canonical **USD** base (money is stored in USD cents) and the **₫** display option,
/// plus foreign catalog regions (GBP/EUR/CAD → USD cents for sets with no US retail).
///
/// Rates are fetched live once per session from a free no-key API; the last successful table is
/// persisted in UserDefaults and re-seeded at launch, so the fallback is the most recent live rate.
/// The hardcoded table is only used on the very first run before any fetch has succeeded.
///
/// Synchronous + lock-protected (not an actor) on purpose: the pure money accessors on the models call
/// it inline, exactly like the Android `object CurrencyConverter`.
final class CurrencyConverter: Sendable {
    static let shared = CurrencyConverter()

    private static let fallbackRates: [String: Double] = [
        "USD": 1.0, "VND": 26_000.0, "GBP": 0.79, "EUR": 0.92, "CAD": 1.36,
    ]
    private static let endpoint = URL(string: "https://open.er-api.com/v6/latest/USD")!
    private static let defaultsKey = "fx_rates.rates_json"
    private static let regionCurrency = ["US": "USD", "UK": "GBP", "CA": "CAD", "DE": "EUR"]

    private struct State {
        var rates: [String: Double]?
        var liveFetched = false
    }

    private let state: OSAllocatedUnfairLock<State>
    private let log = Logger(subsystem: "com.senniapp.brickwares", category: "CurrencyConverter")

    private init() {
        // Seed the last-known live table synchronously so returning users get exact rates at launch.
        state = OSAllocatedUnfairLock(initialState: State(rates: Self.loadPersisted()))
    }

    /// Refresh the live table once per session (idempotent, best-effort, 6s timeout).
    /// Returns true when a fresh table was loaded by this call.
    @discardableResult
    func ensureRatesLoaded() async -> Bool {
        if state.withLock({ $0.liveFetched }) { return false }
        var request = URLRequest(url: Self.endpoint)
        request.timeoutInterval = 6
        do {
            let (data, _) = try await SupabaseProvider.apiSession.data(for: request)
            let fresh = try JSONDecoder().decode(ErApiResponse.self, from: data).rates
            if !fresh.isEmpty, fresh["VND"] != nil {
                state.withLock { $0.rates = fresh; $0.liveFetched = true }
                if let json = try? JSONEncoder().encode(fresh) {
                    UserDefaults.standard.set(json, forKey: Self.defaultsKey)
                }
                return true
            }
        } catch {
            log.warning("Live FX fetch failed; using last-known / fallback rate: \(error.localizedDescription)")
        }
        return false
    }

    private static func loadPersisted() -> [String: Double]? {
        guard let data = UserDefaults.standard.data(forKey: defaultsKey),
              let map = try? JSONDecoder().decode([String: Double].self, from: data), !map.isEmpty
        else { return nil }
        return map
    }

    /// ISO currency for a `set_prices` region, or nil if unknown.
    func currencyForRegion(_ region: String?) -> String? { region.flatMap { Self.regionCurrency[$0] } }

    private func rate(_ code: String) -> Double? {
        state.withLock { $0.rates?[code] } ?? Self.fallbackRates[code]
    }

    private var vndPerUsd: Double { rate("VND") ?? 26_000.0 }

    /// `amount` (in `currency`'s own unit — USD cents, or whole ₫) → canonical **USD cents**.
    func usdCents(of amount: Int64, _ currency: AppCurrency) -> Int64 {
        switch currency {
        case .usd: amount
        case .vnd: Int64(((Double(amount) / vndPerUsd) * 100.0).rounded())
        }
    }

    /// USD cents → `currency`'s own display unit (the inverse of `usdCents(of:)`).
    func fromUsdCents(_ usdCents: Int64, to currency: AppCurrency) -> Int64 {
        switch currency {
        case .usd: usdCents
        case .vnd: Int64(((Double(usdCents) / 100.0) * vndPerUsd).rounded())
        }
    }

    /// Convert between currencies, both in their own unit. **Identity when equal** so a same-currency
    /// value stays exact (no lossy USD round-trip).
    func convert(_ amount: Int64, from: AppCurrency, to: AppCurrency) -> Int64 {
        from == to ? amount : fromUsdCents(usdCents(of: amount, from), to: to)
    }

    /// A catalog region price in its major unit (USD 299.99, GBP 249.99…) → **USD cents**.
    func usdCentsFromRegion(_ amount: Double, regionCurrency: String) -> Int64? {
        let perUsd: Double
        if regionCurrency == "USD" {
            perUsd = 1.0
        } else if let r = rate(regionCurrency) {
            perUsd = r
        } else {
            return nil
        }
        return Int64(((amount / perUsd) * 100.0).rounded())
    }

    private struct ErApiResponse: Decodable {
        var rates: [String: Double] = [:]
    }
}
