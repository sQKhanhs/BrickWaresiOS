import Foundation
import Observation
import SwiftData
import os

/// Debounced, coalesced sync trigger + the app-level sync lifecycle (sign-in, reconnect, writes).
/// A burst of edits yields ONE push + pull + value-warm once it settles; each row keeps its dirty
/// flag until a sync actually runs, so nothing is lost by waiting.
@MainActor
@Observable
final class SyncScheduler {
    private(set) var isSyncing = false
    /// Bumps after every completed sync so list views can re-read rows a background context wrote.
    private(set) var completedRevision = 0

    @ObservationIgnored private let engine: SyncEngine
    @ObservationIgnored private var pending: Task<Void, Never>?
    private static let debounce: Duration = .milliseconds(750)

    init(container: ModelContainer) {
        engine = SyncEngine(modelContainer: container)
    }

    /// Requests a sync after a local write (no-op if signed out). Debounced.
    func requestSync() {
        pending?.cancel()
        pending = Task { [weak self] in
            try? await Task.sleep(for: Self.debounce)
            guard !Task.isCancelled else { return }
            await self?.syncNow()
        }
    }

    /// Full push + pull **now**, bypassing the debounce; suspends until done. False when signed out
    /// or the round-trip failed. Used by the CSV import to hold its blocking progress UI.
    @discardableResult
    func syncNow() async -> Bool {
        guard let uid = AuthService.shared.user?.id, AppConfig.isConfigured else { return false }
        isSyncing = true
        let ok = await engine.sync(uid: uid)
        await finish()
        return ok
    }

    /// Sign-in / cold-start restore: account-switch guard, then a full sync.
    func handleSignedIn(_ user: AuthUser) async {
        isSyncing = true
        let result = await engine.onSignedIn(uid: user.id)
        if result.switched {
            AppSettings.shared.clearFavorites()
            CatalogOverlay.shared.reset()
        }
        await finish()
    }

    /// Account deletion: drop every local row, the cursors, the account guard and the favorites.
    func wipeEverything() async {
        pending?.cancel()
        await engine.wipeLocal()
        SyncStateStore().reset()
        AppSettings.shared.clearFavorites()
        CatalogOverlay.shared.reset()
        completedRevision += 1
    }

    private func finish() async {
        isSyncing = false
        completedRevision += 1
        // Refresh the community value cache so a just-contributed price shows on the cards.
        await ValueService.shared.warm()
    }
}

/// The single funnel for user-data writes. Owns the SwiftData write **and** its side effects —
/// identical-copy merge, owning-an-item-removes-it-from-the-wishlist, the optimistic community-value
/// fold, then a debounced sync. Views never hand-roll `modelContext.insert`.
///
/// Writes land locally first (marking the row dirty, stamping `updatedAt`); the network never blocks
/// a read or a write.
@MainActor
@Observable // only so it can ride in the SwiftUI environment; it has no observed state
final class CollectionService {
    private let context: ModelContext
    private let sync: SyncScheduler
    private let overlay = CatalogOverlay.shared
    private let values = ValueService.shared
    private let log = Logger(subsystem: "com.senniapp.brickwares", category: "CollectionService")

    init(container: ModelContainer, sync: SyncScheduler) {
        context = container.mainContext
        self.sync = sync
    }

    /// What the Add sheet hands over: the catalog item plus the copy being added.
    struct NewCopy {
        var condition: Condition = .new
        var qty = 1
        /// Total for `qty`, in `currency`'s own unit.
        var pricePaid: Int64 = 0
        var currency: AppCurrency = .usd
        /// yyyy-MM-dd, or nil.
        var date: String?
        var note: String?
    }

    // MARK: Collection

    func addCopy(of item: CatalogSet, _ copy: NewCopy) {
        let kind = item.itemType.rawValue
        let isFig = item.itemType == .minifig
        let set = isFig ? nil : (overlay.set(number: item.setNumber) ?? item)
        let now = nowMillis()
        let date = copy.date?.nilIfBlank
        let qty = max(1, copy.qty)

        // A new copy identical in condition, currency, date, note and per-unit paid merges into the
        // existing row (bumps quantity, sums the total) instead of adding a duplicate. Per-unit match
        // is cross-multiplied to avoid integer-division rounding.
        let existing = activeCopies(setNumber: item.setNumber, kind: kind)
        if let match = existing.first(where: {
            $0.condition == copy.condition.rawValue && $0.acquiredOn == date
                && ($0.notes ?? "") == (copy.note ?? "") && $0.currency == copy.currency.rawValue
                && $0.pricePaid * Int64(qty) == copy.pricePaid * Int64($0.quantity)
        }) {
            match.quantity += qty
            match.pricePaid += copy.pricePaid
            touch(match, now)
        } else {
            context.insert(CollectionCopy(
                setId: set?.setId, figNum: isFig ? item.setNumber : nil, itemKind: kind,
                setNumber: item.setNumber, name: item.name, theme: item.theme,
                subtheme: set?.subtheme ?? "General",
                releaseYear: item.releaseYear, releaseMonth: item.releaseMonth,
                pieces: item.pieces, minifigs: item.minifigs,
                retailPrice: set?.retailPrice ?? item.retailPrice.flatMap { $0 > 0 ? $0 : nil },
                status: item.status.rawValue,
                imageUrl: isFig ? item.imageUrl : (set?.thumbnailUrl ?? item.thumbnailUrl ?? item.imageUrl),
                quantity: qty, condition: copy.condition.rawValue,
                pricePaid: copy.pricePaid, currency: copy.currency.rawValue,
                acquiredOn: date, notes: copy.note?.nilIfBlank,
                updatedAt: now, dirty: true
            ))
        }
        contributeLocal(setId: set?.setId, figNum: isFig ? item.setNumber : nil, setNumber: item.setNumber,
                        amount: copy.pricePaid, currency: copy.currency, isSale: false)
        // Owning an item removes it from the wishlist (want → have) — on EVERY add path.
        tombstoneWishlist(setNumber: item.setNumber, now)
        commit()
    }

    func updateCopy(id: String, _ copy: NewCopy) {
        guard let row = (try? CollectionCopy.fetch(ids: [id], in: context))?.first else { return }
        row.quantity = max(1, copy.qty)
        row.condition = copy.condition.rawValue
        row.pricePaid = copy.pricePaid
        row.currency = copy.currency.rawValue
        row.acquiredOn = copy.date?.nilIfBlank
        row.notes = copy.note?.nilIfBlank
        touch(row, nowMillis())
        contributeLocal(setId: row.setId, figNum: row.figNum, setNumber: row.setNumber,
                        amount: copy.pricePaid, currency: copy.currency, isSale: false)
        commit()
    }

    func removeCopy(id: String) {
        guard let row = (try? CollectionCopy.fetch(ids: [id], in: context))?.first else { return }
        tombstone(row, nowMillis())
        commit()
    }

    /// Removes every copy of an item (swipe-to-delete on the Collection card).
    func removeItem(setNumber: String) {
        let now = nowMillis()
        let rows = (try? context.fetch(FetchDescriptor<CollectionCopy>(
            predicate: #Predicate { $0.setNumber == setNumber && !$0.tombstoned }))) ?? []
        rows.forEach { tombstone($0, now) }
        commit()
    }

    // MARK: Sales

    /// Records a sale of an item that isn't (or is no longer) tracked as an owned copy.
    /// `paid` / `salePrice` are totals for `qty`, entered together in one `currency`.
    func addSale(
        of item: CatalogSet, qty: Int, condition: Condition, paid: Int64, salePrice: Int64,
        currency: AppCurrency, soldOn: String?, note: String?
    ) {
        let kind = item.itemType.rawValue
        let isFig = item.itemType == .minifig
        let set = isFig ? nil : (overlay.set(number: item.setNumber) ?? item)
        let now = nowMillis()
        let qty = max(1, qty)
        let soldOn = soldOn?.nilIfBlank
        let note = note?.nilIfBlank

        if let match = activeSales(setNumber: item.setNumber, kind: kind).first(where: {
            $0.condition == condition.rawValue && $0.soldOn == soldOn && ($0.notes ?? "") == (note ?? "")
                && $0.currency == currency.rawValue
                && $0.pricePaid * Int64(qty) == paid * Int64($0.quantity)
                && $0.salePrice * Int64(qty) == salePrice * Int64($0.quantity)
        }) {
            match.quantity += qty
            match.pricePaid += paid
            match.salePrice += salePrice
            touch(match, now)
        } else {
            context.insert(Sale(
                setId: set?.setId, figNum: isFig ? item.setNumber : nil, itemKind: kind,
                setNumber: item.setNumber, name: item.name, theme: item.theme,
                releaseYear: item.releaseYear, releaseMonth: item.releaseMonth,
                imageUrl: isFig ? item.imageUrl : (set?.thumbnailUrl ?? item.thumbnailUrl ?? item.imageUrl),
                retailPrice: set?.retailPrice ?? item.retailPrice.flatMap { $0 > 0 ? $0 : nil },
                quantity: qty, condition: condition.rawValue,
                pricePaid: paid, salePrice: salePrice, currency: currency.rawValue,
                soldOn: soldOn, notes: note, updatedAt: now, dirty: true
            ))
        }
        contributeLocal(setId: set?.setId, figNum: isFig ? item.setNumber : nil, setNumber: item.setNumber,
                        amount: salePrice, currency: currency, isSale: true)
        commit()
    }

    /// Sells `quantity` units out of an owned copy. The copy's paid cost is **prorated** so profit has
    /// a fair basis and paid stays conserved between the remaining copy and the sale. The sale price is
    /// typed in the display `currency`; the cost basis is converted into it so the row is single-currency.
    func sellCopy(id: String, quantity: Int, salePrice: Int64, currency: AppCurrency, soldOn: String?) {
        guard let copy = (try? CollectionCopy.fetch(ids: [id], in: context))?.first else { return }
        let available = copy.quantity
        let sellQty = min(max(1, quantity), max(1, available))
        let soldPaidCopyCcy = available <= 0 ? 0 : copy.pricePaid * Int64(sellQty) / Int64(available)
        let soldPaid = CurrencyConverter.shared.convert(soldPaidCopyCcy, from: AppCurrency(wire: copy.currency), to: currency)
        let now = nowMillis()
        let soldOn = soldOn?.nilIfBlank

        if let match = activeSales(setNumber: copy.setNumber, kind: copy.itemKind).first(where: {
            $0.condition == copy.condition && $0.soldOn == soldOn && ($0.notes ?? "") == (copy.notes ?? "")
                && $0.currency == currency.rawValue
                && $0.pricePaid * Int64(sellQty) == soldPaid * Int64($0.quantity)
                && $0.salePrice * Int64(sellQty) == salePrice * Int64($0.quantity)
        }) {
            match.quantity += sellQty
            match.pricePaid += soldPaid
            match.salePrice += salePrice
            touch(match, now)
        } else {
            context.insert(Sale(
                setId: copy.setId, figNum: copy.figNum, itemKind: copy.itemKind,
                setNumber: copy.setNumber, name: copy.name, theme: copy.theme,
                releaseYear: copy.releaseYear, releaseMonth: copy.releaseMonth,
                imageUrl: copy.imageUrl, retailPrice: copy.retailPrice,
                quantity: sellQty, condition: copy.condition,
                pricePaid: soldPaid, salePrice: salePrice, currency: currency.rawValue,
                soldOn: soldOn, notes: copy.notes, updatedAt: now, dirty: true
            ))
        }
        if sellQty >= available {
            tombstone(copy, now)
        } else {
            copy.quantity = available - sellQty
            copy.pricePaid -= soldPaidCopyCcy
            touch(copy, now)
        }
        contributeLocal(setId: copy.setId, figNum: copy.figNum, setNumber: copy.setNumber,
                        amount: salePrice, currency: currency, isSale: true)
        commit()
    }

    func updateSale(
        id: String, quantity: Int, condition: Condition, paid: Int64, salePrice: Int64,
        currency: AppCurrency, soldOn: String?, note: String?
    ) {
        guard let row = (try? Sale.fetch(ids: [id], in: context))?.first else { return }
        row.quantity = max(1, quantity)
        row.condition = condition.rawValue
        row.pricePaid = paid
        row.salePrice = salePrice
        row.currency = currency.rawValue
        row.soldOn = soldOn?.nilIfBlank
        row.notes = note?.nilIfBlank
        touch(row, nowMillis())
        contributeLocal(setId: row.setId, figNum: row.figNum, setNumber: row.setNumber,
                        amount: salePrice, currency: currency, isSale: true)
        commit()
    }

    func removeSale(id: String) {
        guard let row = (try? Sale.fetch(ids: [id], in: context))?.first else { return }
        tombstone(row, nowMillis())
        commit()
    }

    // MARK: Wishlist

    func addToWishlist(_ item: CatalogSet) {
        let number = item.setNumber
        let already = ((try? context.fetchCount(FetchDescriptor<WishlistItem>(
            predicate: #Predicate { $0.setNumber == number && !$0.tombstoned }))) ?? 0) > 0
        guard !already else { return }
        let isFig = item.itemType == .minifig
        let set = isFig ? nil : (overlay.set(number: number) ?? item)
        context.insert(WishlistItem(
            setId: set?.setId, figNum: isFig ? number : nil, itemKind: item.itemType.rawValue,
            setNumber: number, name: item.name, theme: item.theme, subtheme: set?.subtheme ?? "General",
            releaseYear: item.releaseYear, releaseMonth: item.releaseMonth,
            pieces: item.pieces, minifigs: item.minifigs,
            retailPrice: set?.retailPrice ?? item.retailPrice.flatMap { $0 > 0 ? $0 : nil },
            status: item.status.rawValue,
            imageUrl: isFig ? item.imageUrl : (set?.thumbnailUrl ?? item.thumbnailUrl ?? item.imageUrl),
            updatedAt: nowMillis(), dirty: true
        ))
        commit()
    }

    func removeFromWishlist(setNumber: String) {
        tombstoneWishlist(setNumber: setNumber, nowMillis())
        commit()
    }

    func toggleWishlist(_ item: CatalogSet, isWishlisted: Bool) {
        isWishlisted ? removeFromWishlist(setNumber: item.setNumber) : addToWishlist(item)
    }

    // MARK: CSV (Settings → Data)

    func exportCSV() -> String {
        CollectionCSV.encode(
            copies: (try? CollectionCopy.fetchActive(in: context)) ?? [],
            sales: (try? Sale.fetchActive(in: context)) ?? [],
            wishlist: (try? WishlistItem.fetchActive(in: context)) ?? []
        )
    }

    /// Full-snapshot overwrite: tombstone every current row (so the removals push), insert the parsed
    /// rows as fresh dirty rows, then sync NOW and wait. The file is validated before anything is
    /// touched, so picking the wrong file can never wipe data. Returns the imported row count.
    func importCSV(_ text: String) async throws -> Int {
        let parsed = CollectionCSV.parse(text)
        guard parsed.header.contains("set_number"), parsed.header.contains("item_kind") else {
            throw CollectionCSV.ImportError.notABrickWaresExport
        }
        let version = CollectionCSV.version(of: parsed)
        guard version <= CollectionCSV.formatVersion else { throw CollectionCSV.ImportError.tooNew(version) }

        // A hand-edited file may omit set_id — resolve those in ONE batch catalog query.
        let needIds = Set(parsed.rows.compactMap { row -> String? in
            let isFig = row.value("item_kind")?.lowercased() == "minifig"
            return (isFig || row.value("set_id") != nil) ? nil : row.value("set_number")
        })
        let resolved = ((try? await CatalogRepository.shared.fetchSets(numbers: needIds)) ?? [])
            .reduce(into: [String: Int64]()) { acc, s in if let id = s.setId { acc[s.setNumber] = id } }

        let now = nowMillis()
        let imported = CollectionCSV.rows(from: parsed, setIdByNumber: resolved, now: now)

        for row in (try? CollectionCopy.fetchActive(in: context)) ?? [] { tombstone(row, now) }
        for row in (try? Sale.fetchActive(in: context)) ?? [] { tombstone(row, now) }
        for row in (try? WishlistItem.fetchActive(in: context)) ?? [] { tombstone(row, now) }
        imported.copies.forEach(context.insert)
        imported.sales.forEach(context.insert)
        imported.wishlist.forEach(context.insert)
        try context.save()
        await sync.syncNow() // best-effort: offline → already local, a reconnect pushes it later
        return imported.copies.count + imported.sales.count + imported.wishlist.count
    }

    // MARK: Helpers

    private func activeCopies(setNumber: String, kind: String) -> [CollectionCopy] {
        (try? context.fetch(FetchDescriptor<CollectionCopy>(
            predicate: #Predicate { $0.setNumber == setNumber && $0.itemKind == kind && !$0.tombstoned }))) ?? []
    }

    private func activeSales(setNumber: String, kind: String) -> [Sale] {
        (try? context.fetch(FetchDescriptor<Sale>(
            predicate: #Predicate { $0.setNumber == setNumber && $0.itemKind == kind && !$0.tombstoned }))) ?? []
    }

    private func tombstoneWishlist(setNumber: String, _ now: Int64) {
        let rows = (try? context.fetch(FetchDescriptor<WishlistItem>(
            predicate: #Predicate { $0.setNumber == setNumber && !$0.tombstoned }))) ?? []
        rows.forEach { tombstone($0, now) }
    }

    private func touch(_ row: some SyncableRow, _ now: Int64) {
        row.updatedAt = now
        row.dirty = true
    }

    /// Soft delete: tombstones sync like any edit and reads filter them out. Never a hard delete.
    private func tombstone(_ row: some SyncableRow, _ now: Int64) {
        row.tombstoned = true
        touch(row, now)
    }

    private func commit() {
        do { try context.save() } catch { log.error("save failed: \(error.localizedDescription)") }
        sync.requestSync()
    }

    /// Reflect a just-written price in the community value cache immediately, using the live catalog
    /// retail/status so the outlier guard matches what `ValueService.warm()` will later compute.
    private func contributeLocal(
        setId: Int64?, figNum: String?, setNumber: String, amount: Int64, currency: AppCurrency, isSale: Bool
    ) {
        guard amount > 0 else { return }
        if let figNum {
            values.applyLocal(setId: nil, figNum: figNum, amount: amount, currency: currency,
                              retail: nil, tier: .noAnchor, isSale: isSale)
        } else if let setId {
            let cat = overlay.set(id: setId, number: setNumber)
            let tier = ValueAggregator.tier(
                for: cat?.status ?? .available, retiredYear: cat?.retiredYear ?? 0, retiredMonth: cat?.retiredMonth ?? 0
            )
            values.applyLocal(setId: setId, figNum: nil, amount: amount, currency: currency,
                              retail: cat?.retailPrice, tier: tier, isSale: isSale)
        }
    }
}
