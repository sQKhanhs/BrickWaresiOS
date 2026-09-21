import Foundation
import Supabase

/// Supabase-backed read-only catalog. Every call is a bounded server-side query — browse/search over
/// indexed columns and count views, single-row detail fetches, and batch resolves for the user's
/// referenced sets/figs. Nothing is held in memory (the catalog is 23k+ sets).
///
/// All methods throw on failure so callers can show error/retry; all are `@concurrent` so row
/// mapping (date parsing for a ~2k-set theme) never runs on the main actor.
final class CatalogRepository: Sendable {
    static let shared = CatalogRepository(client: SupabaseProvider.client)

    private let client: SupabaseClient

    private static let loadTimeout = 15.0
    /// Max keys per `in.(...)` batch, so a large collection can't blow the URL length.
    private static let inChunk = 200
    private static let pageSize = 1000
    /// Brickset's placeholder name for an announced-but-unnamed set — filtered out everywhere.
    private static let unrevealedName = "{?}"

    private static let setCols =
        "set_id,set_number,number_variant,name,item_type,theme,subtheme,box_image_url,render_url,year,pieces,"
        + "minifigs,availability,notes,notes_vi,launch_date,exit_date,"
        + "set_prices(region,retail_price,date_first_available,date_last_available)"
    private static let minifigCols = "fig_num,name,num_parts,image_url,set_minifigs(set_id,sets(theme,subtheme))"

    init(client: SupabaseClient) {
        self.client = client
    }

    // MARK: Sets

    @concurrent
    func searchSets(_ query: String, limit: Int = 25) async throws -> [CatalogSet] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return [] }
        let p = Self.orValue(Self.likePattern(q))
        let rows: [SetRow] = try await run {
            try await $0.from("sets").select(Self.setCols)
                .neq("name", value: Self.unrevealedName)
                .or("set_number.ilike.\(p),name.ilike.\(p),theme.ilike.\(p)")
                .order("year", ascending: false)
                .limit(limit)
                .execute().value
        }
        return Self.revealed(rows).uniqued(by: \.id)
    }

    @concurrent
    func themeCounts() async throws -> [ThemeCount] {
        let rows: [ThemeCountRow] = try await allPages { $0.from("catalog_theme_counts").select().order("theme") }
        return rows.map { ThemeCount(theme: $0.theme, count: $0.setCount) }
    }

    @concurrent
    func subthemeCounts() async throws -> [ThemeSubthemeCount] {
        // 1,696 rows in prod — well past the page cap, so this MUST page (see `allPages`).
        let rows: [SubthemeCountRow] = try await allPages {
            $0.from("catalog_subtheme_counts").select().order("theme").order("subtheme")
        }
        return rows.map { ThemeSubthemeCount(theme: $0.theme, subtheme: $0.subtheme, count: $0.setCount) }
    }

    /// All sets of one theme (bounded ~1–2k); the caller filters subthemes / sorts / paginates in memory.
    @concurrent
    func setsInTheme(_ theme: String) async throws -> [CatalogSet] {
        // The big themes exceed the page cap (Gear 3.5k, Duplo 1.4k, Star Wars 1.1k, City 1k).
        let rows: [SetRow] = try await allPages {
            $0.from("sets").select(Self.setCols)
                .eq("theme", value: theme)
                .neq("name", value: Self.unrevealedName)
                .order("set_id")
        }
        return Self.revealed(rows).uniqued(by: \.id)
    }

    /// A bounded slice of a theme (its most recent sets) — the pool the detail page draws its random
    /// recommendations from, without downloading a 1k+ set theme.
    @concurrent
    func recentSets(inTheme theme: String, limit: Int = 60) async throws -> [CatalogSet] {
        let rows: [SetRow] = try await run {
            try await $0.from("sets").select(Self.setCols)
                .eq("theme", value: theme)
                .neq("name", value: Self.unrevealedName)
                .order("year", ascending: false)
                .order("set_id", ascending: false)
                .limit(limit)
                .execute().value
        }
        return Self.revealed(rows).uniqued(by: \.id)
    }

    /// `catalogKey` is `CatalogSet.id` ("<number>-<variant>") or a bare number. Exact number+variant
    /// first, then the number's lowest variant.
    @concurrent
    func fetchSet(_ catalogKey: String) async throws -> CatalogSet? {
        let number: String
        let variant: Int?
        if let dash = catalogKey.lastIndex(of: "-"), dash != catalogKey.startIndex,
           let v = Int(catalogKey[catalogKey.index(after: dash)...]) {
            variant = v
            number = String(catalogKey[..<dash])
        } else {
            variant = nil
            number = catalogKey
        }
        var row: SetRow?
        if let variant {
            let exact: [SetRow] = try await run {
                try await $0.from("sets").select(Self.setCols)
                    .eq("set_number", value: number).eq("number_variant", value: variant)
                    .limit(1).execute().value
            }
            row = exact.first
        }
        if row == nil {
            let any: [SetRow] = try await run {
                try await $0.from("sets").select(Self.setCols)
                    .eq("set_number", value: number)
                    .order("number_variant", ascending: true)
                    .limit(1).execute().value
            }
            row = any.first
        }
        return row.map { $0.toCatalogSet() }.flatMap { Self.isRevealed($0) ? $0 : nil }
    }

    /// Batch resolve by set number; lowest variant per number wins (stable for CMF-style numbers).
    @concurrent
    func fetchSets(numbers: some Collection<String>) async throws -> [CatalogSet] {
        let keys = Array(Set(numbers.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }))
        guard !keys.isEmpty else { return [] }
        var rows: [SetRow] = []
        for chunk in keys.chunked(Self.inChunk) {
            rows += try await run {
                try await $0.from("sets").select(Self.setCols)
                    .in("set_number", values: chunk)
                    .neq("name", value: Self.unrevealedName)
                    .order("number_variant", ascending: true)
                    .execute().value
            } as [SetRow]
        }
        var best: [String: CatalogSet] = [:]
        for s in Self.revealed(rows) {
            if let cur = best[s.setNumber], cur.numberVariant <= s.numberVariant { continue }
            best[s.setNumber] = s
        }
        return Array(best.values)
    }

    @concurrent
    func fetchSets(ids: some Collection<Int64>) async throws -> [CatalogSet] {
        let keys = Array(Set(ids)).map { Int($0) }
        guard !keys.isEmpty else { return [] }
        var rows: [SetRow] = []
        for chunk in keys.chunked(Self.inChunk) {
            rows += try await run {
                try await $0.from("sets").select(Self.setCols).in("set_id", values: chunk).execute().value
            } as [SetRow]
        }
        return rows.map { $0.toCatalogSet() }.uniqued(by: \.setId)
    }

    /// Candidates for "New sets": launch date ≥ the first day of the previous month. `NewSets`
    /// narrows to the exact rule.
    @concurrent
    func newSetCandidates() async throws -> [CatalogSet] {
        let cal = Calendar.current
        let firstOfMonth = cal.date(from: cal.dateComponents([.year, .month], from: Date())) ?? Date()
        let cutoff = LocalDay(date: cal.date(byAdding: .month, value: -1, to: firstOfMonth) ?? firstOfMonth).iso
        let rows: [SetRow] = try await run {
            try await $0.from("sets").select(Self.setCols)
                .gte("launch_date", value: cutoff)
                .neq("name", value: Self.unrevealedName)
                .execute().value
        }
        return Self.revealed(rows).uniqued(by: \.id)
    }

    // MARK: Minifigs

    @concurrent
    func searchMinifigs(_ query: String, limit: Int = 25) async throws -> [Minifig] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return [] }
        let p = Self.orValue(Self.likePattern(q))
        let rows: [MinifigRow] = try await run {
            try await $0.from("minifigs").select(Self.minifigCols)
                .or("fig_num.ilike.\(p),name.ilike.\(p)")
                .limit(limit)
                .execute().value
        }
        return rows.map { $0.toMinifig() }.uniqued(by: \.figNum)
    }

    @concurrent
    func minifigThemeCounts() async throws -> [ThemeCount] {
        let rows: [MinifigThemeCountRow] = try await allPages {
            $0.from("catalog_minifig_theme_counts").select().order("theme")
        }
        return rows.map { ThemeCount(theme: $0.theme, count: $0.minifigCount) }
    }

    @concurrent
    func minifigSubthemeCounts() async throws -> [ThemeSubthemeCount] {
        let rows: [MinifigSubthemeCountRow] = try await allPages {
            $0.from("catalog_minifig_subtheme_counts").select().order("theme").order("subtheme")
        }
        return rows.map { ThemeSubthemeCount(theme: $0.theme, subtheme: $0.subtheme, count: $0.minifigCount) }
    }

    /// `!inner` so only figs that appear in a set of this theme come back; the embedded sets are also
    /// filtered to this theme, which is what the in-theme browse wants.
    @concurrent
    func minifigsInTheme(_ theme: String) async throws -> [Minifig] {
        let rows: [MinifigRow] = try await allPages {
            $0.from("minifigs")
                .select("fig_num,name,num_parts,image_url,set_minifigs!inner(set_id,sets!inner(theme,subtheme))")
                .eq("set_minifigs.sets.theme", value: theme)
                .order("fig_num")
        }
        return rows.map { $0.toMinifig() }.uniqued(by: \.figNum)
    }

    @concurrent
    func fetchMinifig(_ figNum: String) async throws -> Minifig? {
        let rows: [MinifigRow] = try await run {
            try await $0.from("minifigs").select(Self.minifigCols).eq("fig_num", value: figNum).limit(1).execute().value
        }
        return rows.first?.toMinifig()
    }

    @concurrent
    func fetchMinifigs(figNums: some Collection<String>) async throws -> [Minifig] {
        let keys = Array(Set(figNums.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }))
        guard !keys.isEmpty else { return [] }
        var rows: [MinifigRow] = []
        for chunk in keys.chunked(Self.inChunk) {
            rows += try await run {
                try await $0.from("minifigs").select(Self.minifigCols).in("fig_num", values: chunk).execute().value
            } as [MinifigRow]
        }
        return rows.map { $0.toMinifig() }.uniqued(by: \.figNum)
    }

    /// Sets a minifig appears in, newest first.
    @concurrent
    func fetchSets(forMinifig figNum: String) async throws -> [CatalogSet] {
        let rows: [SetWrapperRow] = try await run {
            try await $0.from("set_minifigs").select("sets(\(Self.setCols))").eq("fig_num", value: figNum).execute().value
        }
        return Self.revealed(rows.compactMap(\.sets)).uniqued(by: \.id).sorted { $0.releaseYear > $1.releaseYear }
    }

    /// Figs in a set. The grid needs only identity/image, so the theme join is skipped.
    @concurrent
    func fetchMinifigs(forSet setId: Int64) async throws -> [Minifig] {
        let rows: [MinifigWrapperRow] = try await run {
            try await $0.from("set_minifigs").select("minifigs(fig_num,name,num_parts,image_url)")
                .eq("set_id", value: Int(setId)).execute().value
        }
        return rows.compactMap { $0.minifigs?.toMinifig() }.uniqued(by: \.figNum).sorted { $0.figNum < $1.figNum }
    }

    // MARK: Helpers

    /// PostgREST silently caps a response at `max_rows` (1000), so any query that can exceed it must
    /// walk pages — with a stable `order`, or rows shuffle between pages. `build` returns the ordered
    /// query; this adds the range and drains it.
    private func allPages<T: Decodable & Sendable>(
        _ build: @escaping @Sendable (SupabaseClient) -> PostgrestTransformBuilder
    ) async throws -> [T] {
        var all: [T] = []
        var from = 0
        while true {
            let start = from
            let page: [T] = try await run {
                try await build($0).range(from: start, to: start + Self.pageSize - 1).execute().value
            }
            all += page
            if page.count < Self.pageSize { break }
            from += Self.pageSize
        }
        return all
    }

    private func run<T: Sendable>(_ body: @escaping @Sendable (SupabaseClient) async throws -> T) async throws -> T {
        let client = client
        return try await withTimeout(seconds: Self.loadTimeout) { try await body(client) }
    }

    /// Escape the user's text so their `%`/`_` are literal in the ILIKE pattern.
    private static func likePattern(_ q: String) -> String {
        "%" + q.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "%", with: "\\%")
            .replacingOccurrences(of: "_", with: "\\_") + "%"
    }

    /// A value inside an `or=(…)` expression must be double-quoted when it contains PostgREST's
    /// reserved characters (`,` `.` `:` `(` `)`), else a query like "Spider-Man, Venom" breaks the filter.
    private static func orValue(_ v: String) -> String {
        "\"" + v.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }

    private static func isRevealed(_ s: CatalogSet) -> Bool {
        let n = s.name.trimmingCharacters(in: .whitespaces)
        return !n.isEmpty && n != unrevealedName
    }

    private static func revealed(_ rows: [SetRow]) -> [CatalogSet] {
        rows.map { $0.toCatalogSet() }.filter(isRevealed)
    }
}

// MARK: - Row DTOs

private struct ThemeCountRow: Decodable, Sendable {
    var theme: String
    var setCount: Int
    enum CodingKeys: String, CodingKey { case theme; case setCount = "set_count" }
}

private struct SubthemeCountRow: Decodable, Sendable {
    var theme: String
    var subtheme: String
    var setCount: Int
    enum CodingKeys: String, CodingKey { case theme, subtheme; case setCount = "set_count" }
}

private struct MinifigThemeCountRow: Decodable, Sendable {
    var theme: String
    var minifigCount: Int
    enum CodingKeys: String, CodingKey { case theme; case minifigCount = "minifig_count" }
}

private struct MinifigSubthemeCountRow: Decodable, Sendable {
    var theme: String
    var subtheme: String
    var minifigCount: Int
    enum CodingKeys: String, CodingKey { case theme, subtheme; case minifigCount = "minifig_count" }
}

private struct SetWrapperRow: Decodable, Sendable { var sets: SetRow? }
private struct MinifigWrapperRow: Decodable, Sendable { var minifigs: MinifigRow? }

private struct PriceRow: Decodable, Sendable {
    var region: String?
    var retailPrice: Double?
    var dateFirstAvailable: String?
    var dateLastAvailable: String?

    enum CodingKeys: String, CodingKey {
        case region
        case retailPrice = "retail_price"
        case dateFirstAvailable = "date_first_available"
        case dateLastAvailable = "date_last_available"
    }
}

private struct SetRow: Decodable, Sendable {
    var setId: Int64?
    var setNumber: String
    var numberVariant: Int?
    var name: String?
    var itemType: String?
    var boxImageUrl: String?
    var renderUrl: String?
    var theme: String?
    var subtheme: String?
    var year: Int?
    var pieces: Int?
    var minifigs: Int?
    /// Brickset sales channel: "Retail", "LEGO exclusive", "Promotional", "Magazine gift", …
    var availability: String?
    var notes: String?
    var notesVi: String?
    var launchDate: String?
    var exitDate: String?
    var prices: [PriceRow]?

    enum CodingKeys: String, CodingKey {
        case setId = "set_id", setNumber = "set_number", numberVariant = "number_variant", name
        case itemType = "item_type", boxImageUrl = "box_image_url", renderUrl = "render_url"
        case theme, subtheme, year, pieces, minifigs, availability, notes
        case notesVi = "notes_vi", launchDate = "launch_date", exitDate = "exit_date", prices = "set_prices"
    }

    /// Retail in **USD cents**: the US price exact (× 100, no FX); else any region cross-converted.
    private var retailUsdCents: Int64? {
        let all = prices ?? []
        guard let chosen = all.first(where: { $0.region == "US" && $0.retailPrice != nil })
            ?? all.first(where: { $0.retailPrice != nil }),
            let amount = chosen.retailPrice,
            let currency = CurrencyConverter.shared.currencyForRegion(chosen.region)
        else { return nil }
        return CurrencyConverter.shared.usdCentsFromRegion(amount, regionCurrency: currency)
    }

    /// Prefer the Brickset set-level launch date, else the earliest LEGO.com first-available date.
    private var releaseDate: LocalDay? {
        LocalDay(launchDate) ?? (prices ?? []).compactMap { LocalDay($0.dateFirstAvailable) }.min()
    }

    /// Prefer the Brickset exit date, else the latest LEGO.com last-available date. nil = still sold.
    private var retirementDate: LocalDay? {
        LocalDay(exitDate) ?? (prices ?? []).compactMap { LocalDay($0.dateLastAvailable) }.max()
    }

    private func deriveStatus(today: LocalDay) -> Availability {
        // Not yet released → Pending, ahead of everything else.
        if let r = releaseDate, r > today { return .pending }
        // Promo items + magazine gifts are never sold at retail and get no exit date, so they keep
        // their own badge and are NEVER marked retired.
        let channel = (availability ?? "").lowercased()
        if channel == "promotional" { return .promo }
        if channel == "magazine gift" { return .magazine }
        if let retire = retirementDate, retire < today { return .retired }
        // A legacy set with no date data at all can't be dated; a past-year one is retired.
        if releaseDate == nil, let y = year, y >= 1, y < today.year { return .retired }
        if channel == "lego exclusive" { return .exclusive }
        if channel == "lego gift with purchase" { return .gwp }
        return .available
    }

    func toCatalogSet() -> CatalogSet {
        let today = LocalDay.today
        let release = releaseDate
        let retiredPast = retirementDate.flatMap { $0 < today ? $0 : nil }
        let variant = numberVariant ?? 1
        let render = renderUrl?.nilIfBlank
        return CatalogSet(
            setNumber: setNumber,
            name: name ?? "",
            itemType: ItemType(wire: itemType),
            theme: theme ?? "",
            releaseYear: release?.year ?? year ?? 0,
            releaseMonth: release?.month ?? 0,
            pieces: pieces ?? 0,
            minifigs: minifigs ?? 0,
            retailPrice: retailUsdCents,
            status: deriveStatus(today: today),
            retiredYear: retiredPast?.year ?? 0,
            retiredMonth: retiredPast?.month ?? 0,
            subtheme: subtheme ?? "General",
            // Prefer the ingest-captured authoritative render (correct for multi-variant numbers).
            imageUrl: render ?? CatalogImages.renderUrl(setNumber, variant: variant),
            boxImageUrl: boxImageUrl?.nilIfBlank,
            thumbnailUrl: render.map { CatalogImages.thumbFromRender($0) } ?? CatalogImages.thumbUrl(setNumber, variant: variant),
            numberVariant: variant,
            notes: notes?.nilIfBlank,
            notesVi: notesVi?.nilIfBlank,
            setId: setId
        )
    }
}

private struct MinifigRow: Decodable, Sendable {
    struct SetMinifigRow: Decodable, Sendable {
        var setId: Int64?
        var sets: SetThemeRow?
        enum CodingKeys: String, CodingKey { case setId = "set_id", sets }
    }

    struct SetThemeRow: Decodable, Sendable {
        var theme: String?
        var subtheme: String?
    }

    var figNum: String
    var name: String?
    var numParts: Int?
    var imageUrl: String?
    var setMinifigs: [SetMinifigRow]?

    enum CodingKeys: String, CodingKey {
        case figNum = "fig_num", name, numParts = "num_parts", imageUrl = "image_url", setMinifigs = "set_minifigs"
    }

    func toMinifig() -> Minifig {
        let joins = setMinifigs ?? []
        let pairs = joins.compactMap { sm -> Minifig.ThemePair? in
            guard let theme = sm.sets?.theme?.nilIfBlank else { return nil }
            return Minifig.ThemePair(theme: theme, subtheme: sm.sets?.subtheme?.nilIfBlank ?? "General")
        }
        return Minifig(
            figNum: figNum, name: name ?? figNum, imageUrl: imageUrl,
            numParts: numParts ?? 0, setCount: joins.count,
            themeSubthemes: pairs.uniqued(by: \.self),
            setIds: joins.compactMap(\.setId).uniqued(by: \.self)
        )
    }
}

// MARK: - Small collection helpers

extension Array {
    func chunked(_ size: Int) -> [[Element]] {
        guard size > 0 else { return [self] }
        return stride(from: 0, to: count, by: size).map { Array(self[$0..<Swift.min($0 + size, count)]) }
    }

    /// Order-preserving de-duplication by key (Kotlin's `distinctBy`).
    func uniqued<K: Hashable>(by key: (Element) -> K) -> [Element] {
        var seen = Set<K>()
        return filter { seen.insert(key($0)).inserted }
    }
}
