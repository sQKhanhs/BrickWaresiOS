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
    @ObservationIgnored private var retry: Task<Void, Never>?
    @ObservationIgnored private var retryAttempt = 0
    private static let debounce: Duration = .milliseconds(750)

    init(container: ModelContainer) {
        engine = SyncEngine(modelContainer: container)
    }

    /// Requests a sync after a local write (no-op if signed out). Debounced.
    func requestSync() {
        resetRetry() // a fresh request restarts the backoff schedule
        pending?.cancel()
        pending = Task { [weak self] in
            try? await Task.sleep(for: Self.debounce)
            guard !Task.isCancelled else { return }
            await self?.syncNow()
        }
    }

    /// Full pull + push **now**, bypassing the debounce; suspends until done. False when signed out
    /// or the round-trip failed. Used by the CSV import to hold its blocking progress UI.
    @discardableResult
    func syncNow() async -> Bool {
        guard let uid = AuthService.shared.user?.id, AppConfig.isConfigured else { return false }
        isSyncing = true
        let ok = await engine.sync(uid: uid)
        scheduleRetry(after: ok)
        await finish()
        return ok
    }

    /// Sign-in / cold-start restore: account-switch guard, then a full sync.
    func handleSignedIn(_ user: AuthUser) async {
        isSyncing = true
        let result = await engine.onSignedIn(uid: user.id)
        scheduleRetry(after: result.ok)
        if result.switched {
            AppSettings.shared.clearFavorites()
            CatalogOverlay.shared.reset()
        }
        await finish()
    }

    /// Account deletion: drop every local row, the cursors, the account guard and the favorites.
    func wipeEverything() async {
        pending?.cancel()
        resetRetry()
        await engine.wipeLocal()
        SyncStateStore().reset()
        AppSettings.shared.clearFavorites()
        CatalogOverlay.shared.reset()
        completedRevision += 1
    }

    /// A round that failed while the device believes it's online is retried on a short bounded backoff
    /// (`SyncRules.retryDelays`, Android parity): the reconnect edge can fire a beat before the network
    /// actually routes, and one failed attempt would strand dirty rows until the next write or foreground.
    /// Offline, nothing is scheduled — the reconnect edge requests a sync instead.
    private func scheduleRetry(after ok: Bool) {
        if ok { resetRetry(); return }
        guard retry == nil, retryAttempt < SyncRules.retryDelays.count, Connectivity.shared.isOnline else { return }
        let delay = SyncRules.retryDelays[retryAttempt]
        retryAttempt += 1
        retry = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled, let self else { return }
            // Release the handle BEFORE syncing: a failed retry schedules the next attempt from inside this
            // task, and the `retry == nil` guard would otherwise see this task and stop.
            self.retry = nil
            guard Connectivity.shared.isOnline else { return }
            await self.syncNow()
        }
    }

    private func resetRetry() {
        retry?.cancel()
        retry = nil
        retryAttempt = 0
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
        // A CMF (Collectible Minifigure) is minifig-KIND but lives in the `sets` table with a real
        // set_id, so it must be stored by set_id like any set — only an in-set fig (built via
        // `fromMinifig`, no set_id) is referenced by fig_num. Resolving by id also dodges the CMF
        // number ambiguity (a CMF series shares one set_number across variants).
        let isFig = item.itemType == .minifig && item.setId == nil
        let set = isFig ? nil : (overlay.set(id: item.setId, number: item.setNumber) ?? item)
        // The row identity, resolved ONCE and used for the merge lookup, the insert AND the wishlist
        // removal alike (Android parity): the SELECTED variant's set_id, else the catalog-resolved one.
        // Looking up by one key and inserting under another split a card on every add.
        let rowSetId = isFig ? nil : (item.setId ?? set?.setId)
        let now = nowMillis()
        let date = copy.date?.nilIfBlank
        // Clamp to the server's CHECK limits before anything goes dirty (see `UserDataLimits`).
        let qty = UserDataLimits.capQty(copy.qty)
        let paid = UserDataLimits.capPrice(copy.pricePaid)
        let note = UserDataLimits.capNote(copy.note?.nilIfBlank)

        // A new copy identical in condition, currency, date, note and per-unit paid merges into the
        // existing row (bumps quantity, sums the total) instead of adding a duplicate. Per-unit match
        // is cross-multiplied to avoid integer-division rounding. A merge that would pass the server's
        // quantity or price cap is refused (a fresh row is added) rather than clamped.
        let existing = activeCopies(setId: rowSetId, setNumber: item.setNumber, kind: kind)
        if let match = existing.first(where: {
            $0.condition == copy.condition.rawValue && $0.acquiredOn == date
                && ($0.notes ?? "") == (note ?? "") && $0.currency == copy.currency.rawValue
                && $0.pricePaid * Int64(qty) == paid * Int64($0.quantity)
                && Self.canMerge(existingQty: $0.quantity, addedQty: qty, prices: [($0.pricePaid, paid)])
        }) {
            match.quantity += qty
            match.pricePaid += paid
            touch(match, now)
        } else {
            context.insert(CollectionCopy(
                setId: rowSetId, figNum: isFig ? item.setNumber : nil, itemKind: kind,
                setNumber: item.setNumber, name: item.name, theme: item.theme,
                subtheme: set?.subtheme ?? "General",
                releaseYear: item.releaseYear, releaseMonth: item.releaseMonth,
                pieces: item.pieces, minifigs: item.minifigs,
                retailPrice: set?.retailPrice ?? item.retailPrice.flatMap { $0 > 0 ? $0 : nil },
                status: item.status.rawValue,
                imageUrl: isFig ? item.imageUrl : (set?.thumbnailUrl ?? item.thumbnailUrl ?? item.imageUrl),
                quantity: qty, condition: copy.condition.rawValue,
                pricePaid: paid, currency: copy.currency.rawValue,
                acquiredOn: date, notes: note,
                updatedAt: now, dirty: true
            ))
        }
        contributeLocal(setId: rowSetId, figNum: isFig ? item.setNumber : nil, setNumber: item.setNumber,
                        amount: paid, currency: copy.currency, isSale: false)
        // Owning an item removes it from the wishlist (want → have) — on EVERY add path, keyed by the same
        // row identity, so owning one figure of a CMF series only clears THAT figure.
        wishlistRows(setId: rowSetId, setNumber: item.setNumber).forEach { tombstone($0, now) }
        commit()
    }

    func updateCopy(id: String, _ copy: NewCopy) {
        guard let row = (try? CollectionCopy.fetch(ids: [id], in: context))?.first else { return }
        row.quantity = UserDataLimits.capQty(copy.qty)
        row.condition = copy.condition.rawValue
        row.pricePaid = UserDataLimits.capPrice(copy.pricePaid)
        row.currency = copy.currency.rawValue
        row.acquiredOn = copy.date?.nilIfBlank
        row.notes = UserDataLimits.capNote(copy.note?.nilIfBlank)
        touch(row, nowMillis())
        contributeLocal(setId: row.setId, figNum: row.figNum, setNumber: row.setNumber,
                        amount: row.pricePaid, currency: copy.currency, isSale: false)
        commit()
    }

    func removeCopy(id: String) {
        guard let row = (try? CollectionCopy.fetch(ids: [id], in: context))?.first else { return }
        tombstone(row, nowMillis())
        commit()
    }

    /// Removes every copy of ONE item (swipe-to-delete on a Collection card): by set_id for a cataloged
    /// set, so only this variant of a shared number goes; else by number among set_id-less rows.
    func removeItem(setNumber: String, setId: Int64?) {
        let now = nowMillis()
        activeCopies(setId: setId, setNumber: setNumber, kind: nil).forEach { tombstone($0, now) }
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
        // CMF (minifig-kind, has set_id) → stored by set_id; only fig_num-keyed in-set figs are figs.
        let isFig = item.itemType == .minifig && item.setId == nil
        let set = isFig ? nil : (overlay.set(id: item.setId, number: item.setNumber) ?? item)
        let rowSetId = isFig ? nil : (item.setId ?? set?.setId) // one identity for lookup + insert
        let now = nowMillis()
        let qty = UserDataLimits.capQty(qty)
        let paid = UserDataLimits.capPrice(paid)
        let salePrice = UserDataLimits.capPrice(salePrice)
        let soldOn = soldOn?.nilIfBlank
        let note = UserDataLimits.capNote(note?.nilIfBlank)

        if let match = activeSales(setId: rowSetId, setNumber: item.setNumber, kind: kind).first(where: {
            $0.condition == condition.rawValue && $0.soldOn == soldOn && ($0.notes ?? "") == (note ?? "")
                && $0.currency == currency.rawValue
                && $0.pricePaid * Int64(qty) == paid * Int64($0.quantity)
                && $0.salePrice * Int64(qty) == salePrice * Int64($0.quantity)
                && Self.canMerge(existingQty: $0.quantity, addedQty: qty,
                                 prices: [($0.pricePaid, paid), ($0.salePrice, salePrice)])
        }) {
            match.quantity += qty
            match.pricePaid += paid
            match.salePrice += salePrice
            touch(match, now)
        } else {
            context.insert(Sale(
                setId: rowSetId, figNum: isFig ? item.setNumber : nil, itemKind: kind,
                setNumber: item.setNumber, name: item.name, theme: item.theme,
                releaseYear: item.releaseYear, releaseMonth: item.releaseMonth,
                imageUrl: isFig ? item.imageUrl : (set?.thumbnailUrl ?? item.thumbnailUrl ?? item.imageUrl),
                retailPrice: set?.retailPrice ?? item.retailPrice.flatMap { $0 > 0 ? $0 : nil },
                quantity: qty, condition: condition.rawValue,
                pricePaid: paid, salePrice: salePrice, currency: currency.rawValue,
                soldOn: soldOn, notes: note, updatedAt: now, dirty: true
            ))
        }
        contributeLocal(setId: rowSetId, figNum: isFig ? item.setNumber : nil, setNumber: item.setNumber,
                        amount: salePrice, currency: currency, isSale: true)
        commit()
    }

    /// Sells `quantity` units out of an owned copy. The copy's paid cost is **prorated** so profit has
    /// a fair basis and paid stays conserved between the remaining copy and the sale. The sale price is
    /// typed in the display `currency`; the cost basis is converted into it so the row is single-currency.
    func sellCopy(id: String, quantity: Int, salePrice: Int64, currency: AppCurrency, soldOn: String?) {
        guard let copy = (try? CollectionCopy.fetch(ids: [id], in: context))?.first else { return }
        let available = copy.quantity
        // Nothing to sell (a legacy 0-quantity copy — the server's CHECK allows 0, so one can arrive by
        // sync): recording it would invent a 1-unit sale at zero cost. Tombstone the empty row instead.
        guard available > 0 else {
            tombstone(copy, nowMillis())
            commit()
            return
        }
        let sellQty = min(max(1, quantity), available)
        let soldPaidCopyCcy = available <= 0 ? 0 : copy.pricePaid * Int64(sellQty) / Int64(available)
        let soldPaid = UserDataLimits.capPrice(
            CurrencyConverter.shared.convert(soldPaidCopyCcy, from: AppCurrency(wire: copy.currency), to: currency))
        let salePrice = UserDataLimits.capPrice(salePrice)
        let now = nowMillis()
        let soldOn = soldOn?.nilIfBlank

        if let match = activeSales(setId: copy.setId, setNumber: copy.setNumber, kind: copy.itemKind).first(where: {
            $0.condition == copy.condition && $0.soldOn == soldOn && ($0.notes ?? "") == (copy.notes ?? "")
                && $0.currency == currency.rawValue
                && $0.pricePaid * Int64(sellQty) == soldPaid * Int64($0.quantity)
                && $0.salePrice * Int64(sellQty) == salePrice * Int64($0.quantity)
                && Self.canMerge(existingQty: $0.quantity, addedQty: sellQty,
                                 prices: [($0.pricePaid, soldPaid), ($0.salePrice, salePrice)])
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
        row.quantity = UserDataLimits.capQty(quantity)
        row.condition = condition.rawValue
        row.pricePaid = UserDataLimits.capPrice(paid)
        row.salePrice = UserDataLimits.capPrice(salePrice)
        row.currency = currency.rawValue
        row.soldOn = soldOn?.nilIfBlank
        row.notes = UserDataLimits.capNote(note?.nilIfBlank)
        touch(row, nowMillis())
        contributeLocal(setId: row.setId, figNum: row.figNum, setNumber: row.setNumber,
                        amount: row.salePrice, currency: currency, isSale: true)
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
        // CMF (minifig-kind, has set_id) → stored by set_id; only fig_num-keyed in-set figs are figs.
        let isFig = item.itemType == .minifig && item.setId == nil
        let set = isFig ? nil : (overlay.set(id: item.setId, number: number) ?? item)
        let rowSetId = isFig ? nil : (item.setId ?? set?.setId)
        // Already wishlisted? Per variant: one figure of a CMF series must not block another.
        guard wishlistRows(setId: rowSetId, setNumber: number).isEmpty else { return }
        context.insert(WishlistItem(
            setId: rowSetId, figNum: isFig ? number : nil, itemKind: item.itemType.rawValue,
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

    /// Un-wishlists ONE item (a Wishlist card): by set_id for a cataloged set — this variant only — else
    /// by number among set_id-less rows (in-set minifigs, legacy rows).
    func removeFromWishlist(setNumber: String, setId: Int64?) {
        let now = nowMillis()
        wishlistRows(setId: setId, setNumber: setNumber).forEach { tombstone($0, now) }
        commit()
    }

    func toggleWishlist(_ item: CatalogSet, isWishlisted: Bool) {
        guard isWishlisted else { addToWishlist(item); return }
        // From a catalog card: its exact variant, plus a legacy set_id-less row of its number — that is
        // what `OwnershipIndex.isWishlisted` matched, so the heart must be able to clear it too.
        let now = nowMillis()
        var rows = wishlistRows(setId: item.setId, setNumber: item.setNumber)
        if item.setId != nil { rows += wishlistRows(setId: nil, setNumber: item.setNumber) }
        rows.forEach { tombstone($0, now) }
        commit()
    }

    // MARK: CSV (Settings → Data)

    func exportCSV() -> String {
        CollectionCSV.encode(
            copies: (try? CollectionCopy.fetchActive(in: context)) ?? [],
            sales: (try? Sale.fetchActive(in: context)) ?? [],
            wishlist: (try? WishlistItem.fetchActive(in: context)) ?? [],
            // The exact variant from the row's set_id only (the overlay resolves every referenced id).
            variantOf: { [overlay] setId in setId.flatMap { overlay.set(id: $0)?.numberVariant } }
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

        // A hand-edited or legacy file may omit set_id — resolve those in ONE batch catalog query that
        // returns EVERY variant per number (the lowest-only lookup would pin a CMF row to variant 1).
        let needIds = Set(parsed.rows.compactMap { row -> String? in
            let isFig = row.value("item_kind")?.lowercased() == "minifig"
            return (isFig || row.value("set_id") != nil) ? nil : row.value("set_number")
        })
        let variants = Dictionary(grouping: (try? await CatalogRepository.shared.fetchSetVariants(numbers: needIds)) ?? [],
                                  by: \.setNumber)

        let now = nowMillis()
        let imported = CollectionCSV.rows(from: parsed, now: now) { number, variant in
            CollectionCSV.resolveSetId(variant: variant, among: variants[number] ?? [])
        }
        // A hand-edited file can carry anything — clamp to the server's CHECK limits before it goes dirty.
        for row in imported.copies {
            row.quantity = UserDataLimits.capQty(row.quantity)
            row.pricePaid = UserDataLimits.capPrice(row.pricePaid)
            row.notes = UserDataLimits.capNote(row.notes)
        }
        for row in imported.sales {
            row.quantity = UserDataLimits.capQty(row.quantity)
            row.pricePaid = UserDataLimits.capPrice(row.pricePaid)
            row.salePrice = UserDataLimits.capPrice(row.salePrice)
            row.notes = UserDataLimits.capNote(row.notes)
        }

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

    /// Whether merging `addedQty` units (and each `(existing, added)` price pair) into an existing row stays
    /// within the server's caps. Past a cap the merge is refused and a fresh row is added instead —
    /// clamping would keep the row valid but silently drop units or money.
    private static func canMerge(existingQty: Int, addedQty: Int, prices: [(Int64, Int64)]) -> Bool {
        UserDataLimits.canMergeQty(existing: existingQty, added: addedQty)
            && prices.allSatisfy { $0.0 + $0.1 <= UserDataLimits.maxPriceMinor }
    }

    // Rows of ONE item (see `ItemKey`): by set_id for a cataloged set, so each variant of a shared number
    // is its own item; else — an in-set minifig or a legacy row — by number among set_id-less rows ONLY,
    // so a number match can never reach into a cataloged variant. `kind` nil = any kind.

    private func activeCopies(setId: Int64?, setNumber: String, kind: String?) -> [CollectionCopy] {
        let rows: [CollectionCopy]
        if let setId {
            let id: Int64? = setId
            rows = (try? context.fetch(FetchDescriptor<CollectionCopy>(
                predicate: #Predicate { $0.setId == id && !$0.tombstoned }))) ?? []
        } else {
            rows = (try? context.fetch(FetchDescriptor<CollectionCopy>(
                predicate: #Predicate { $0.setId == nil && $0.setNumber == setNumber && !$0.tombstoned }))) ?? []
        }
        return kind.map { k in rows.filter { $0.itemKind == k } } ?? rows
    }

    private func activeSales(setId: Int64?, setNumber: String, kind: String) -> [Sale] {
        let rows: [Sale]
        if let setId {
            let id: Int64? = setId
            rows = (try? context.fetch(FetchDescriptor<Sale>(
                predicate: #Predicate { $0.setId == id && !$0.tombstoned }))) ?? []
        } else {
            rows = (try? context.fetch(FetchDescriptor<Sale>(
                predicate: #Predicate { $0.setId == nil && $0.setNumber == setNumber && !$0.tombstoned }))) ?? []
        }
        return rows.filter { $0.itemKind == kind }
    }

    private func wishlistRows(setId: Int64?, setNumber: String) -> [WishlistItem] {
        if let setId {
            let id: Int64? = setId
            return (try? context.fetch(FetchDescriptor<WishlistItem>(
                predicate: #Predicate { $0.setId == id && !$0.tombstoned }))) ?? []
        }
        return (try? context.fetch(FetchDescriptor<WishlistItem>(
            predicate: #Predicate { $0.setId == nil && $0.setNumber == setNumber && !$0.tombstoned }))) ?? []
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
