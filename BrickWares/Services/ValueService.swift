import Foundation
import Observation
import Supabase
import os

/// The crowdsourced "current value" engine. Reads the public, identity-stripped `set_value_points`
/// view (never the base table — `id`/`user_id` are not selectable there) and folds the rows into a
/// displayed `CurrentValue` client-side. Writes happen elsewhere: the sync engine publishes paid/sale
/// prices through the `contribute_value` RPC once the owning row has synced.
///
/// An in-memory cache is warmed in bulk so item cards can overlay the value synchronously; `revision`
/// bumps whenever it changes so views that read it re-render.
@MainActor
@Observable
final class ValueService {
    static let shared = ValueService()

    private(set) var revision = 0

    @ObservationIgnored private var setCache: [Int64: CurrentValue] = [:]
    @ObservationIgnored private var figCache: [String: CurrentValue] = [:]
    // The raw points behind each cached value, kept so a locally-edited price can be folded in and
    // re-aggregated immediately (see `applyLocal`) instead of waiting for a sync round-trip.
    @ObservationIgnored private var setPoints: [Int64: [ValuePoint]] = [:]
    @ObservationIgnored private var figPoints: [String: [ValuePoint]] = [:]

    private nonisolated static let table = "set_value_points"
    private nonisolated static let timeout = 8.0
    private nonisolated static let pageSize = 1000
    private nonisolated static let log = Logger(subsystem: "com.senniapp.brickwares", category: "ValueService")

    private init() {}

    // MARK: Cache reads (synchronous overlay)

    func value(forSet setId: Int64?) -> CurrentValue? {
        _ = revision // register the observation dependency
        return setId.flatMap { setCache[$0] }
    }

    func value(forFig figNum: String?) -> CurrentValue? {
        _ = revision
        return figNum.flatMap { figCache[$0] }
    }

    func value(setId: Int64?, figNum: String?) -> CurrentValue? {
        figNum != nil ? value(forFig: figNum) : value(forSet: setId)
    }

    // MARK: Bulk warm

    /// Bulk-refresh the cache: fetch every public contribution and aggregate per item. Best-effort —
    /// a failure leaves the previous cache intact.
    func warm() async {
        guard AppConfig.isConfigured else { return }
        guard let result = await Self.loadAll() else { return }
        setPoints = result.setPoints
        figPoints = result.figPoints
        setCache = result.setValues
        figCache = result.figValues
        revision += 1
    }

    private struct Warmed: Sendable {
        var setPoints: [Int64: [ValuePoint]]
        var figPoints: [String: [ValuePoint]]
        var setValues: [Int64: CurrentValue]
        var figValues: [String: CurrentValue]
    }

    @concurrent
    private static func loadAll() async -> Warmed? {
        let client = SupabaseProvider.client
        var rows: [Row] = []
        do {
            // PostgREST caps a page (max_rows = 1000), so walk the view until a short page.
            var offset = 0
            while true {
                let from = offset
                let page: [Row] = try await withTimeout(seconds: timeout) {
                    try await client.from(table).select()
                        .order("submitted_at", ascending: true)
                        .range(from: from, to: from + pageSize - 1)
                        .execute().value
                }
                rows += page
                if page.count < pageSize { break }
                offset += pageSize
            }
        } catch {
            log.warning("value warm failed: \(error.localizedDescription)")
            return nil
        }

        let now = ValueAggregator.nowMs()
        let bySet = Dictionary(grouping: rows.filter { $0.setId != nil }, by: { $0.setId! })
        let byFig = Dictionary(grouping: rows.filter { $0.figNum != nil }, by: { $0.figNum! })
        // Resolve the retail/status anchor for the contributed sets in ONE batch query; an unresolved
        // set falls back to the no-retail absolute band.
        let catalog = ((try? await CatalogRepository.shared.fetchSets(ids: bySet.keys)) ?? [])
            .reduce(into: [Int64: CatalogSet]()) { acc, s in if let id = s.setId { acc[id] = s } }

        var warmed = Warmed(setPoints: [:], figPoints: [:], setValues: [:], figValues: [:])
        for (id, rs) in bySet {
            let pts = rs.map(\.point)
            let set = catalog[id]
            let tier = ValueAggregator.tier(
                for: set?.status ?? .available, retiredYear: set?.retiredYear ?? 0,
                retiredMonth: set?.retiredMonth ?? 0, nowMs: now
            )
            warmed.setPoints[id] = pts
            warmed.setValues[id] = ValueAggregator.aggregate(pts, retailUsdCents: set?.retailPrice, tier: tier, nowMs: now)
        }
        for (fig, rs) in byFig {
            let pts = rs.map(\.point)
            warmed.figPoints[fig] = pts
            warmed.figValues[fig] = ValueAggregator.aggregate(pts, retailUsdCents: nil, tier: .noAnchor, nowMs: now)
        }
        return warmed
    }

    // MARK: Optimistic local fold

    /// Fold the current user's own just-written price into the local value for one item and
    /// re-aggregate at once, so a paid add/edit is reflected immediately. `warm()` later replaces it
    /// with the DB-accurate value.
    func applyLocal(
        setId: Int64?, figNum: String?, amount: Int64, currency: AppCurrency,
        retail: Int64?, tier: ValueGuardTier, isSale: Bool
    ) {
        let usdCents = CurrencyConverter.shared.usdCents(of: amount, currency)
        guard amount > 0, usdCents > 0 else { return }
        let now = ValueAggregator.nowMs()
        let point = ValuePoint(
            value: Double(usdCents), submittedAtMs: now, isSale: isSale, nativeMinor: amount, nativeCurrency: currency
        )
        if let figNum {
            let pts = (figPoints[figNum] ?? []) + [point]
            figCache[figNum] = ValueAggregator.aggregate(pts, retailUsdCents: nil, tier: .noAnchor, nowMs: now)
        } else if let setId {
            let pts = (setPoints[setId] ?? []) + [point]
            setCache[setId] = ValueAggregator.aggregate(pts, retailUsdCents: retail, tier: tier, nowMs: now)
        } else {
            return
        }
        revision += 1
    }

    // MARK: One-item fetch (detail pages)

    /// Fresh value for one set (retail + tier anchor the outlier guard). `.none` on failure.
    func fetch(forSet setId: Int64, retailUsdCents: Int64?, tier: ValueGuardTier) async -> CurrentValue {
        let rows = await Self.loadRows(column: "set_id", value: Int(setId))
        return ValueAggregator.aggregate(rows.map(\.point), retailUsdCents: retailUsdCents, tier: tier)
    }

    /// Fresh value for one minifig (no retail anchor → the absolute sanity band applies).
    func fetch(forFig figNum: String) async -> CurrentValue {
        let rows = await Self.loadRows(column: "fig_num", value: figNum)
        return ValueAggregator.aggregate(rows.map(\.point), retailUsdCents: nil, tier: .noAnchor)
    }

    @concurrent
    private static func loadRows(column: String, value: some PostgrestFilterValue & Sendable) async -> [Row] {
        guard AppConfig.isConfigured else { return [] }
        let client = SupabaseProvider.client
        do {
            return try await withTimeout(seconds: timeout) {
                try await client.from(table).select().eq(column, value: value).execute().value
            }
        } catch {
            log.warning("value fetch failed: \(error.localizedDescription)")
            return []
        }
    }

    private struct Row: Decodable, Sendable {
        var setId: Int64?
        var figNum: String?
        var value: Double
        var currency: String?
        var submittedAt: String?
        var source: String?

        enum CodingKeys: String, CodingKey {
            case setId = "set_id", figNum = "fig_num", value, currency, submittedAt = "submitted_at", source
        }

        /// Each contribution is recorded in its own currency; normalize to USD cents so the
        /// median/guard compare like with like against the USD-cents retail anchor.
        var point: ValuePoint {
            let ccy = AppCurrency(wire: currency)
            let native = Int64(value.rounded())
            return ValuePoint(
                value: Double(CurrencyConverter.shared.usdCents(of: native, ccy)),
                submittedAtMs: ISO8601.millis(submittedAt),
                isSale: source == "sale", nativeMinor: native, nativeCurrency: ccy
            )
        }
    }
}

/// Timestamp helpers for PostgREST `timestamptz` strings ("…Z" or "…+00:00", with or without
/// fractional seconds — Postgres emits microseconds).
enum ISO8601 {
    /// Epoch millis, or 0 on a missing/unparseable stamp (so LWW keeps local, like Android).
    static func millis(_ s: String?) -> Int64 {
        guard let s, let date = date(s) else { return 0 }
        return Int64((date.timeIntervalSince1970 * 1000).rounded())
    }

    static func date(_ s: String) -> Date? {
        let withFraction = ISO8601DateFormatter()
        withFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = withFraction.date(from: s) { return d }
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        return plain.date(from: s)
    }

    /// `Instant.toString()` analog: UTC, millisecond precision, "Z" suffix.
    static func string(millis: Int64) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        f.timeZone = TimeZone(secondsFromGMT: 0)
        return f.string(from: Date(timeIntervalSince1970: Double(millis) / 1000))
    }
}
