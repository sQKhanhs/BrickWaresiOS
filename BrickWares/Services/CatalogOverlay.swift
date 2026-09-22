import Foundation
import Observation
import os

/// User-scoped catalog cache: only the sets/figs the user's rows reference, so the cards get fresh
/// reference data (status, box image, release-month backfill, minifig image/set-count) without the
/// client holding the whole catalog. Empty until the first fetch and after an offline failure — the
/// cards then fall back to each row's denormalized fields.
@MainActor
@Observable
final class CatalogOverlay {
    static let shared = CatalogOverlay()

    /// Bumps whenever the maps change so views that read them re-render.
    private(set) var revision = 0
    /// True once an authoritative overlay has loaded at least once.
    private(set) var isReady = false

    @ObservationIgnored private var setsById: [Int64: CatalogSet] = [:]
    @ObservationIgnored private var setsByNumber: [String: CatalogSet] = [:]
    @ObservationIgnored private var figsByNum: [String: Minifig] = [:]
    @ObservationIgnored private var loadedKeys: ReferencedKeys?

    private let log = Logger(subsystem: "com.senniapp.brickwares", category: "CatalogOverlay")

    private init() {}

    struct ReferencedKeys: Hashable, Sendable {
        var setNumbers: Set<String> = []
        var figNums: Set<String> = []

        mutating func add(kind: String, setNumber: String, figNum: String?) {
            if kind == "minifig", let figNum {
                // In-set minifig: keyed by its Rebrickable fig_num, fetched from the `minifigs` catalog.
                figNums.insert(figNum)
            } else {
                // Sets, and CMFs (minifig-KIND rows that live in the `sets` table with no fig_num) —
                // both resolve against the set catalog by number (and, at read time, by set_id).
                setNumbers.insert(setNumber)
            }
        }
    }

    func set(id: Int64?, number: String) -> CatalogSet? {
        _ = revision
        return id.flatMap { setsById[$0] } ?? setsByNumber[number]
    }

    func set(number: String) -> CatalogSet? {
        _ = revision
        return setsByNumber[number]
    }

    func minifig(_ figNum: String?) -> Minifig? {
        _ = revision
        return figNum.flatMap { figsByNum[$0] }
    }

    /// Rebuild the maps when the referenced keys changed. Keeps the last-known cache on failure.
    func refresh(_ keys: ReferencedKeys, force: Bool = false) async {
        guard force || keys != loadedKeys else { return }
        do {
            try await load(keys)
        } catch {
            log.warning("referenced-catalog refresh failed: \(error.localizedDescription)")
        }
    }

    /// Throwing variant for callers that must know it worked (the retirement check).
    func load(_ keys: ReferencedKeys) async throws {
        guard AppConfig.isConfigured else { return }
        let sets = try await CatalogRepository.shared.fetchSets(numbers: keys.setNumbers)
        let figs = try await CatalogRepository.shared.fetchMinifigs(figNums: keys.figNums)
        setsByNumber = sets.reduce(into: [:]) { $0[$1.setNumber] = $1 }
        setsById = sets.reduce(into: [:]) { acc, s in if let id = s.setId { acc[id] = s } }
        figsByNum = figs.reduce(into: [:]) { $0[$1.figNum] = $1 }
        loadedKeys = keys
        isReady = true
        revision += 1
    }

    func reset() {
        setsById = [:]; setsByNumber = [:]; figsByNum = [:]
        loadedKeys = nil
        isReady = false
        revision += 1
    }
}

// MARK: - Row → display model builders

/// Builds the display models the cards render from the persisted rows + the live overlays. Reference
/// data (status, release month…) prefers the live catalog value and falls back to the stored one.
@MainActor
enum DisplayBuilder {
    private static var overlay: CatalogOverlay { .shared }
    private static var values: ValueService { .shared }

    static func collectionItems(_ rows: [CollectionCopy]) -> [CollectionItem] {
        var order: [String] = []
        var groups: [String: [CollectionCopy]] = [:]
        for row in rows where !row.tombstoned {
            if groups[row.setNumber] == nil { order.append(row.setNumber) }
            groups[row.setNumber, default: []].append(row)
        }
        return order.compactMap { groups[$0] }.map { collectionItem($0) }
    }

    static func collectionItem(_ group: [CollectionCopy]) -> CollectionItem {
        let head = group[0]
        let cat = overlay.set(id: head.setId, number: head.setNumber)
        let fig = overlay.minifig(head.figNum)
        let value = values.value(setId: head.setId, figNum: head.figNum)
        let status = cat?.status ?? Availability(wire: head.status)
        // Minifig-kind items (both in-set figs and CMFs, which carry no fig_num) always surface a
        // community value — key off the kind, not the presence of a fig_num.
        let isMinifig = head.itemKind == "minifig"
        let valueShown = isMinifig || status.showsCommunityValue
        let retail = head.retailPrice ?? 0

        // Growth vs what was paid, per unit — everything in USD cents. The reference is the current
        // value when shown, else retail. Every card gets a growth as long as something was paid.
        let fx = CurrencyConverter.shared
        let totalQty = group.reduce(0) { $0 + $1.quantity }
        let paidUsd = group.reduce(Int64(0)) { $0 + fx.usdCents(of: $1.pricePaid, AppCurrency(wire: $1.currency)) }
        let unitPaid = totalQty > 0 ? Double(paidUsd) / Double(totalQty) : 0
        let growthRef: Int64? = (valueShown ? value?.amountUsdCents : nil) ?? (retail > 0 ? retail : nil)
        let growth: Double? = growthRef.flatMap { unitPaid > 0 ? (Double($0) - unitPaid) / unitPaid * 100.0 : nil }

        return CollectionItem(
            setNumber: head.setNumber, name: head.name, itemType: ItemType(wire: head.itemKind),
            theme: head.theme,
            releaseYear: (cat?.releaseYear).flatMap { $0 > 0 ? $0 : nil } ?? head.releaseYear,
            releaseMonth: cat?.releaseMonth ?? head.releaseMonth,
            pieces: head.pieces, minifigs: head.minifigs, minifigSetCount: fig?.setCount ?? 0,
            retailPrice: retail, currentValueInfo: value, growthPercent: growth, status: status,
            // Minifigs overlay the catalog image (older rows were stored without it).
            imageUrl: fig?.imageUrl ?? head.imageUrl,
            boxImageUrl: cat?.boxImageUrl,
            copies: group.map {
                OwnedCopy(
                    id: $0.id, condition: Condition(wire: $0.condition), qty: $0.quantity,
                    pricePaid: $0.pricePaid, currency: AppCurrency(wire: $0.currency),
                    dateAdded: $0.acquiredOn ?? "", note: $0.notes
                )
            },
            setId: head.setId, figNum: head.figNum
        )
    }

    static func wishlist(_ rows: [WishlistItem]) -> [WishlistEntry] {
        rows.filter { !$0.tombstoned }.map { row in
            let cat = overlay.set(id: row.setId, number: row.setNumber)
            return WishlistEntry(
                rowId: row.id, setNumber: row.setNumber, name: row.name,
                itemType: ItemType(wire: row.itemKind), theme: row.theme,
                releaseYear: (cat?.releaseYear).flatMap { $0 > 0 ? $0 : nil } ?? row.releaseYear,
                releaseMonth: cat?.releaseMonth ?? row.releaseMonth,
                pieces: row.pieces, minifigs: row.minifigs, retailPrice: row.retailPrice ?? 0,
                currentValueInfo: values.value(setId: row.setId, figNum: row.figNum),
                status: cat?.status ?? Availability(wire: row.status),
                imageUrl: overlay.minifig(row.figNum)?.imageUrl ?? row.imageUrl,
                boxImageUrl: cat?.boxImageUrl, addedAt: row.updatedAt,
                setId: row.setId, figNum: row.figNum
            )
        }
    }

    static func sold(_ rows: [Sale]) -> [SoldItem] {
        rows.filter { !$0.tombstoned }.map { row in
            let cat = overlay.set(id: row.setId, number: row.setNumber)
            // In-set figs resolve their image via fig_num; CMFs (no fig_num) fall back to the stored
            // image, and their catalog data comes from `cat` (resolved by set_id above).
            let figKey = row.figNum
            return SoldItem(
                id: row.id, setNumber: row.setNumber, name: row.name,
                itemType: ItemType(wire: row.itemKind), theme: row.theme,
                releaseYear: (cat?.releaseYear).flatMap { $0 > 0 ? $0 : nil } ?? row.releaseYear,
                releaseMonth: cat?.releaseMonth ?? row.releaseMonth,
                pieces: cat?.pieces ?? 0, minifigs: cat?.minifigs ?? 0,
                imageUrl: overlay.minifig(figKey)?.imageUrl ?? row.imageUrl,
                boxImageUrl: cat?.boxImageUrl,
                retailPrice: row.retailPrice ?? 0, pricePaid: row.pricePaid, saleValue: row.salePrice,
                currency: AppCurrency(wire: row.currency), quantity: row.quantity,
                condition: Condition(wire: row.condition), soldOn: row.soldOn, note: row.notes,
                status: cat?.status ?? .available,
                currentValueInfo: values.value(setId: row.setId, figNum: row.figNum),
                setId: row.setId, figNum: row.figNum
            )
        }
    }

    static func referencedKeys(_ copies: [CollectionCopy], _ wishes: [WishlistItem], _ sales: [Sale]) -> CatalogOverlay.ReferencedKeys {
        var keys = CatalogOverlay.ReferencedKeys()
        for r in copies where !r.tombstoned { keys.add(kind: r.itemKind, setNumber: r.setNumber, figNum: r.figNum) }
        for r in wishes where !r.tombstoned { keys.add(kind: r.itemKind, setNumber: r.setNumber, figNum: r.figNum) }
        for r in sales where !r.tombstoned { keys.add(kind: r.itemKind, setNumber: r.setNumber, figNum: r.figNum) }
        return keys
    }
}
