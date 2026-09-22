import Foundation

/// One owned copy of an item. An item can hold several copies bought at different times, conditions
/// and prices — this is what See Details lists and what the Add sheet creates.
struct OwnedCopy: Identifiable, Hashable, Sendable {
    var id: String
    var condition: Condition
    var qty: Int
    /// Total paid for this copy's qty, in `currency`'s own unit (USD cents / whole ₫).
    var pricePaid: Int64
    /// The currency `pricePaid` was entered in (recorded, never converted).
    var currency: AppCurrency = .usd
    /// ISO yyyy-MM-dd, or "" when unknown.
    var dateAdded: String
    var note: String?
}

/// An owned item (set or minifig) plus its copies — the display model the Collection cards render.
/// Built on the fly from `CollectionCopy` rows + the catalog overlay + the value cache.
struct CollectionItem: Identifiable, Hashable, Sendable {
    var setNumber: String
    var name: String
    var itemType: ItemType
    var theme: String
    var releaseYear: Int
    var releaseMonth: Int
    var pieces: Int
    var minifigs: Int
    /// For a minifig item: how many catalog sets it appears in.
    var minifigSetCount = 0
    /// USD cents (0 = no retail data).
    var retailPrice: Int64
    var currentValueInfo: CurrentValue?
    var growthPercent: Double?
    var status: Availability = .available
    var imageUrl: String?
    var boxImageUrl: String?
    var copies: [OwnedCopy] = []
    /// Catalog refs of the underlying rows (first copy), for value lookups + navigation.
    var setId: Int64?
    var figNum: String?

    var id: String { setNumber }
    var currentValue: Int64? { currentValueInfo?.amountUsdCents }
    var totalQty: Int { copies.reduce(0) { $0 + $1.qty } }

    var valueShown: Bool { itemType == .minifig || status.showsCommunityValue }

    /// Total paid across all copies in **USD cents** (each copy normalized first). For cross-item math.
    var totalPaid: Int64 {
        copies.reduce(0) { $0 + CurrencyConverter.shared.usdCents(of: $1.pricePaid, $1.currency) }
    }

    /// Total paid in `display`'s unit, converting each copy **from its own currency** — exact for a
    /// single-currency item (no ₫→cents→₫ drift).
    func totalPaid(in display: AppCurrency) -> Int64 {
        copies.reduce(0) { $0 + CurrencyConverter.shared.convert($1.pricePaid, from: $1.currency, to: display) }
    }

    /// Average paid per **unit** in `display`'s unit.
    func avgPaid(in display: AppCurrency) -> Int64 {
        totalQty == 0 ? 0 : totalPaid(in: display) / Int64(totalQty)
    }

    /// Per-unit "current worth" in USD cents: community value only where it is shown, else retail.
    var worthPerUnit: Int64 { (valueShown ? currentValue : nil) ?? retailPrice }

    /// `worthPerUnit` in `display`'s unit — the exact native amount when recorded in that currency.
    func worthPerUnit(in display: AppCurrency) -> Int64 {
        if valueShown, let v = currentValueInfo?.displayMinor(display) { return v }
        return CurrencyConverter.shared.fromUsdCents(retailPrice, to: display)
    }
}

/// A wishlisted (not-yet-owned) item — CollectionItem's display fields minus ownership.
struct WishlistEntry: Identifiable, Hashable, Sendable {
    var rowId: String
    var setNumber: String
    var name: String
    var itemType: ItemType
    var theme: String
    var releaseYear: Int
    var releaseMonth: Int
    var pieces: Int
    var minifigs: Int
    var retailPrice: Int64
    var currentValueInfo: CurrentValue?
    var status: Availability = .available
    var imageUrl: String?
    var boxImageUrl: String?
    /// Epoch millis.
    var addedAt: Int64 = 0
    /// Catalog refs of the underlying row, for value lookups + navigation (mirrors CollectionItem —
    /// a CMF has setId set + figNum nil, an in-set fig has figNum set + setId nil).
    var setId: Int64?
    var figNum: String?

    var id: String { setNumber }
    var currentValue: Int64? { currentValueInfo?.amountUsdCents }
    var valueShown: Bool { itemType == .minifig || status.showsCommunityValue }
}

/// A sold copy. `pricePaid` / `saleValue` are in `currency`'s own unit (entered together).
struct SoldItem: Identifiable, Hashable, Sendable {
    var id: String
    var setNumber: String
    var name: String
    var itemType: ItemType
    var theme: String
    var releaseYear: Int
    var releaseMonth: Int
    var pieces = 0
    var minifigs = 0
    var imageUrl: String?
    var boxImageUrl: String?
    var retailPrice: Int64
    var pricePaid: Int64
    var saleValue: Int64
    var currency: AppCurrency = .usd
    var quantity = 1
    var condition: Condition = .new
    var soldOn: String?
    var note: String?
    var status: Availability = .available
    var currentValueInfo: CurrentValue?
    /// Catalog refs of the underlying row, for value lookups + navigation (mirrors CollectionItem —
    /// a CMF has setId set + figNum nil, an in-set fig has figNum set + setId nil).
    var setId: Int64?
    var figNum: String?

    var profit: Int64 { saleValue - pricePaid }
    var profitPercent: Double { pricePaid == 0 ? 0 : Double(profit) / Double(pricePaid) * 100.0 }
}

struct SalesSummary: Hashable, Sendable {
    var totalSold: Int
    var totalSaleValue: Int64
    var totalProfit: Int64
    var avgProfitPercent: Double
    var profitPercent: Double
}

/// Home hero / stat-row aggregate. Money is in the display currency it was computed for.
struct CollectionSummary: Hashable, Sendable {
    var setCount: Int
    var minifigCount: Int
    var pieceCount: Int
    var collectionValue: Int64
    var paid: Int64
    var growthPercent: Double
}

struct ThemeSummary: Identifiable, Hashable, Sendable {
    var theme: String
    var setCount: Int
    var totalValue: Int64
    var id: String { theme }
}

// MARK: - Derived stats (mirror Android CollectionStats.kt)

enum CollectionStats {
    /// Money is summed **in `display`** — each item's worth and paid converted from its own currency —
    /// so a single-currency collection's hero total is exact.
    static func summary(of items: [CollectionItem], display: AppCurrency) -> CollectionSummary {
        var sets = 0, figs = 0, pieces = 0
        var value: Int64 = 0, paid: Int64 = 0
        for item in items {
            let qty = item.totalQty
            if item.itemType == .set {
                sets += qty
                figs += item.minifigs * qty
            } else {
                figs += qty // a standalone minifig counts as one minifig
            }
            pieces += item.pieces * qty
            value += item.worthPerUnit(in: display) * Int64(qty)
            paid += item.totalPaid(in: display)
        }
        let growth = paid > 0 ? Double(value - paid) / Double(paid) * 100.0 : 0
        return CollectionSummary(
            setCount: sets, minifigCount: figs, pieceCount: pieces,
            collectionValue: value, paid: paid, growthPercent: growth
        )
    }

    static func salesSummary(of sold: [SoldItem], display: AppCurrency) -> SalesSummary {
        let fx = CurrencyConverter.shared
        let totalPaid = sold.reduce(Int64(0)) { $0 + fx.convert($1.pricePaid, from: $1.currency, to: display) }
        let totalProfit = sold.reduce(Int64(0)) { $0 + fx.convert($1.profit, from: $1.currency, to: display) }
        let totalSale = sold.reduce(Int64(0)) { $0 + fx.convert($1.saleValue, from: $1.currency, to: display) }
        let avg = sold.isEmpty ? 0 : sold.map(\.profitPercent).reduce(0, +) / Double(sold.count)
        let overall = totalPaid == 0 ? 0 : Double(totalProfit) / Double(totalPaid) * 100.0
        return SalesSummary(
            totalSold: sold.count, totalSaleValue: totalSale, totalProfit: totalProfit,
            avgProfitPercent: avg, profitPercent: overall
        )
    }

    /// Per-theme counts + value for Home "Collection by Theme", highest value first.
    static func themeSummaries(of items: [CollectionItem], display: AppCurrency) -> [ThemeSummary] {
        Dictionary(grouping: items, by: \.theme)
            .map { theme, list in
                ThemeSummary(
                    theme: theme,
                    setCount: list.reduce(0) { $0 + $1.totalQty },
                    totalValue: list.reduce(Int64(0)) { $0 + $1.worthPerUnit(in: display) * Int64($1.totalQty) }
                )
            }
            .sorted { $0.totalValue == $1.totalValue ? $0.theme < $1.theme : $0.totalValue > $1.totalValue }
    }
}
