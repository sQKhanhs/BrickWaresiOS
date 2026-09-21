import Foundation

/// Freshness of a computed `CurrentValue`.
enum ValueFreshness: Sendable { case fresh, stale, none }

/// Availability tier for the outlier guard's retail-relative bounds. `noAnchor` (promo / magazine /
/// GWP, minifigs, no-price sets) skips the retail band and uses the absolute USD sanity band.
enum ValueGuardTier: Sendable { case available, retiredRecent, retiredOld, noAnchor }

/// One contributed value point: the amount **in USD cents**, its submission time, whether it came
/// from a realized sale, and the amount as originally recorded (so a single-currency value can be
/// shown in that currency *exactly* instead of drifting through the USD round-trip).
struct ValuePoint: Sendable {
    var value: Double
    var submittedAtMs: Int64
    var isSale = false
    var nativeMinor: Int64 = 0
    var nativeCurrency: AppCurrency?
}

/// The community "current value" for a set or minifig — a recency-tiered median over the public
/// `set_value_points` view (one row per user per item).
struct CurrentValue: Hashable, Sendable {
    /// Displayed median in **USD cents**, or nil when there is no value.
    var amountUsdCents: Int64?
    /// Distinct users backing the shown value.
    var contributionCount: Int
    var freshness: ValueFreshness
    /// Age of the most-recent contribution, for the STALE "last updated …" note.
    var newestAgeDays: Int?
    /// The same median in `nativeCurrency`'s own unit — set only when every contribution shares it.
    var nativeMinor: Int64?
    var nativeCurrency: AppCurrency?

    static let none = CurrentValue(amountUsdCents: nil, contributionCount: 0, freshness: .none, newestAgeDays: nil)

    /// The amount to render in `display`, in its own minor unit: the exact native median when it was
    /// recorded in `display`'s currency, otherwise the USD-cents amount converted. nil when no value.
    func displayMinor(_ display: AppCurrency) -> Int64? {
        guard let usd = amountUsdCents else { return nil }
        if let nativeMinor, nativeCurrency == display { return nativeMinor }
        return CurrencyConverter.shared.fromUsdCents(usd, to: display)
    }
}

/// Turns raw contributions into a displayed `CurrentValue`. Pure + deterministic (clock injected).
///
///  - **Outlier guard** — with a retail anchor, drop points outside a retail-relative band. Lower:
///    60% paid / 70% sale (available), 50% (retired < 2y), 40% (retired ≥ 2y). Upper: 5× / 8× / 20×.
///    Without an anchor, an absolute band of $0.50…$50k applies.
///  - **Median, not average.**
///  - **Tiered recency** — any point in the last ~24 months → median of only those (fresh); otherwise
///    the median of everything left (stale); nothing → none.
enum ValueAggregator {
    private static let recentWindowDays: Int64 = 730
    private static let retiredRecentDays = 730
    private static let absMinUsdCents = 50.0
    private static let absMaxUsdCents = 5_000_000.0
    private static let dayMs: Int64 = 86_400_000

    static func nowMs() -> Int64 { Int64(Date().timeIntervalSince1970 * 1000) }

    static func tier(
        for status: Availability, retiredYear: Int, retiredMonth: Int, nowMs: Int64 = nowMs()
    ) -> ValueGuardTier {
        if status == .promo || status == .magazine || status == .gwp { return .noAnchor }
        guard status == .retired else { return .available }
        guard retiredYear > 0 else { return .retiredOld }
        let calendar = Calendar.current
        let comps = DateComponents(year: retiredYear, month: min(max(retiredMonth, 1), 12), day: 1)
        guard let retiredDate = calendar.date(from: comps) else { return .retiredOld }
        let today = calendar.startOfDay(for: Date(timeIntervalSince1970: Double(nowMs) / 1000))
        let ageDays = calendar.dateComponents([.day], from: retiredDate, to: today).day ?? .max
        return ageDays < retiredRecentDays ? .retiredRecent : .retiredOld
    }

    static func aggregate(
        _ points: [ValuePoint], retailUsdCents: Int64?, tier: ValueGuardTier = .available, nowMs: Int64 = nowMs()
    ) -> CurrentValue {
        let guarded: [ValuePoint]
        if let retail = retailUsdCents, retail > 0, tier != .noAnchor {
            let maxFactor: Double = switch tier {
            case .available: 5.0
            case .retiredRecent: 8.0
            case .retiredOld: 20.0
            case .noAnchor: 0.0
            }
            let hi = Double(retail) * maxFactor
            guarded = points.filter { p in
                let minFactor: Double = switch tier {
                // Available floor is looser for a realized sale than a paid price.
                case .available: p.isSale ? 0.70 : 0.60
                case .retiredRecent: 0.50
                case .retiredOld: 0.40
                case .noAnchor: 0.0
                }
                return p.value >= Double(retail) * minFactor && p.value <= hi
            }
        } else {
            guarded = points.filter { $0.value >= absMinUsdCents && $0.value <= absMaxUsdCents }
        }
        guard !guarded.isEmpty else { return .none }

        let cutoff = nowMs - recentWindowDays * dayMs
        let recent = guarded.filter { $0.submittedAtMs >= cutoff }
        let fresh = !recent.isEmpty
        let used = fresh ? recent : guarded

        let newest = guarded.map(\.submittedAtMs).max() ?? nowMs
        let newestAgeDays = max(0, Int((nowMs - newest) / dayMs))

        // When every point behind the median shares one recorded currency, also express the median in
        // that currency's own unit (FX is monotonic, so the native and USD medians coincide).
        let currencies = Set(used.compactMap(\.nativeCurrency))
        let unanimous: AppCurrency? =
            currencies.count == 1 && used.allSatisfy({ $0.nativeCurrency != nil }) ? currencies.first : nil

        return CurrentValue(
            amountUsdCents: Int64(median(used.map(\.value)).rounded()),
            contributionCount: used.count,
            freshness: fresh ? .fresh : .stale,
            newestAgeDays: newestAgeDays,
            nativeMinor: unanimous.map { _ in Int64(median(used.map { Double($0.nativeMinor) }).rounded()) },
            nativeCurrency: unanimous
        )
    }

    private static func median(_ xs: [Double]) -> Double {
        let s = xs.sorted()
        let n = s.count
        return n % 2 == 1 ? s[n / 2] : (s[n / 2 - 1] + s[n / 2]) / 2.0
    }
}
