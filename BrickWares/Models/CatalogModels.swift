import Foundation

/// Reference/catalog data for a set (from Supabase `sets`). Held transiently — the catalog is never
/// persisted on device (23k+ rows, server-queried on demand).
struct CatalogSet: Identifiable, Hashable, Sendable {
    var setNumber: String
    var name: String
    var itemType: ItemType = .set
    var theme: String
    var releaseYear: Int
    var releaseMonth: Int
    var pieces: Int
    var minifigs: Int
    /// Retail in **USD cents**; nil when the catalog has no retail figure at all.
    var retailPrice: Int64?
    var status: Availability
    var retiredYear: Int = 0
    var retiredMonth: Int = 0
    var subtheme: String = "General"
    var imageUrl: String?
    var boxImageUrl: String?
    var thumbnailUrl: String?
    var numberVariant: Int = 1
    var notes: String?
    var notesVi: String?
    /// Supabase `sets.set_id` — the sync key for user rows.
    var setId: Int64?

    /// Canonical identity: a set number alone is not unique (CMF series share one number across variants).
    var id: String { "\(setNumber)-\(numberVariant)" }
    /// Ownership identity (see `ItemKey`) and the keys it is recognized under (exact variant + legacy number).
    var variantKey: String { ItemKey.of(setId: setId, setNumber: setNumber) }
    var ownershipKeys: [String] { ItemKey.lookup(setId: setId, setNumber: setNumber) }

    /// A minifig represented as a fig-num-keyed CatalogSet so it can flow through the shared Add sheet.
    static func fromMinifig(_ fig: Minifig) -> CatalogSet {
        CatalogSet(
            setNumber: fig.figNum, name: fig.name, itemType: .minifig,
            theme: fig.themes.first ?? "", releaseYear: 0, releaseMonth: 0,
            pieces: fig.numParts, minifigs: 0, retailPrice: nil, status: .available,
            imageUrl: fig.imageUrl, thumbnailUrl: fig.imageUrl
        )
    }
}

/// Reference/catalog data for a minifig (from `minifigs` + the `set_minifigs` join).
struct Minifig: Identifiable, Hashable, Sendable {
    struct ThemePair: Hashable, Sendable {
        var theme: String
        var subtheme: String
    }

    var figNum: String
    var name: String
    var imageUrl: String?
    var numParts: Int = 0
    var setCount: Int = 0
    var themeSubthemes: [ThemePair] = []
    var setIds: [Int64] = []

    var id: String { figNum }

    var themes: [String] {
        var seen = Set<String>()
        return themeSubthemes.map(\.theme).filter { seen.insert($0).inserted }
    }
}

struct ThemeCount: Hashable, Sendable {
    var theme: String
    var count: Int
}

struct ThemeSubthemeCount: Hashable, Sendable {
    var theme: String
    var subtheme: String
    var count: Int
}

/// The keys a Set Detail route accepts (see `CatalogRepository.fetchSet`): a catalog item's `CatalogSet.id`
/// ("<number>-<variant>"), a bare number, or "sid:<set_id>". An owned row knows its set_id but not its
/// variant number, so its card opens "sid:<id>" — the exact variant, not the number's lowest.
enum CatalogKey {
    static func forRow(setId: Int64?, setNumber: String) -> String { setId.map { "sid:\($0)" } ?? setNumber }

    static func setId(_ key: String) -> Int64? {
        guard key.hasPrefix("sid:") else { return nil }
        return Int64(key.dropFirst(4))
    }
}
