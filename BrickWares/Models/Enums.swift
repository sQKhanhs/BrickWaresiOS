import Foundation

/// App-wide currency. **USD is the canonical base** (catalog retail is USD cents); ₫ is a converted
/// display option. An `Int64` amount's unit depends on its currency: USD = integer cents, VND = whole ₫.
/// Raw values are the wire/DB strings shared with Android ("USD" | "VND").
enum AppCurrency: String, Codable, CaseIterable, Sendable, Identifiable {
    case vnd = "VND"
    case usd = "USD"

    var id: String { rawValue }
    var symbol: String { self == .vnd ? "₫" : "$" }

    /// Tolerant parse (CSV / remote rows): unknown → USD, matching Android's `getOrDefault(USD)`.
    init(wire: String?) {
        self = AppCurrency(rawValue: (wire ?? "USD").uppercased()) ?? .usd
    }
}

/// Whether an entry is a set or a minifig. Raw value is the `item_kind` wire string.
enum ItemType: String, Codable, Sendable {
    case set
    case minifig

    init(wire: String?) { self = wire == "minifig" ? .minifig : .set }
}

/// Availability status. Raw values are Android's `Availability.name` (UPPERCASE) because that is what
/// the denormalized `status` column and the CSV export carry — keep them identical so files round-trip
/// across platforms.
enum Availability: String, Codable, Sendable, CaseIterable {
    case available = "AVAILABLE"
    case pending = "PENDING"
    case exclusive = "EXCLUSIVE"
    case gwp = "GWP"
    case promo = "PROMO"
    case magazine = "MAGAZINE"
    case retired = "RETIRED"

    init(wire: String?) { self = Availability(rawValue: (wire ?? "").uppercased()) ?? .available }

    /// The community "current value" is shown only for retired / promo / magazine sets (and minifigs);
    /// an available set is still buyable at retail, so retail is the honest figure there.
    var showsCommunityValue: Bool { self == .retired || self == .promo || self == .magazine }
}

/// Copy condition. Raw value is the `condition` wire string ('new' | 'used').
enum Condition: String, Codable, Sendable, CaseIterable, Identifiable {
    case new
    case used

    var id: String { rawValue }
    init(wire: String?) { self = wire == "used" ? .used : .new }
}
