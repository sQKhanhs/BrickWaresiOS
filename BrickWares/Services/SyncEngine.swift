import Foundation
import SwiftData
import Supabase
import os

/// Two-way sync between SwiftData (local source of truth) and Supabase.
///
/// **Push** = dirty rows upserted by client UUID (idempotent). **Pull** = remote rows whose
/// SERVER-stamped `server_updated_at` is past that table's cursor, merged last-write-wins on the
/// CLIENT `updated_at`; deletes ride the `deleted` tombstone. The two timestamps are deliberately
/// separate: `updated_at` says when the edit happened (even offline) and decides conflicts;
/// `server_updated_at` (DB trigger) says when the row landed and decides what a device still has to
/// fetch — a cursor on client time would miss another device's late-landing offline edit.
///
/// A round PULLS first, then pushes (Android `SyncCoordinator`): a newer remote row — say another
/// device's delete — is applied before a stale offline edit of it could be pushed, and the server's
/// `reject_stale_update` trigger backstops any stale push that slips through. Pull and push are
/// isolated, so a failure in one half never skips the other; the pure rules live in `SyncRules`.
///
/// Runs entirely off the main actor. Each phase uses a **fresh** `ModelContext` so it always reads
/// what the UI's context last saved, and the dirty flag is only cleared when the row is unchanged
/// since it was pushed (an edit made mid-push stays dirty for the next run).
@ModelActor
actor SyncEngine {
    private var running: Task<Bool, Never>?

    private static let log = Logger(subsystem: "com.senniapp.brickwares", category: "Sync")

    private var client: SupabaseClient { SupabaseProvider.client }
    private var syncState: SyncStateStore { SyncStateStore() }

    // MARK: Entry points

    /// Account-switch guard, then a full sync. A *different* account signing in over existing local
    /// data wipes it and re-pulls instead of silently mixing two accounts' rows.
    /// Returns `(ok, switchedAccount)`.
    func onSignedIn(uid: String) async -> (ok: Bool, switched: Bool) {
        var switched = false
        if let last = syncState.lastAccountId, last != uid {
            wipeLocal()
            syncState.clearPullCursors()
            switched = true
        }
        // Record local ownership NOW, before syncing: past this point the local store holds this account's
        // data (freshly wiped for a switch, or already its own). Recording it only after a SUCCESSFUL sync
        // left a window where a failed first sync kept the previous owner — or none — on record, so the
        // next account to sign in skipped the wipe and pushed the first account's dirty rows as its own.
        syncState.setLastAccountId(uid)
        return (await sync(uid: uid), switched)
    }

    /// Full push + pull, serialized: a call made while a sync is running waits for it, then runs
    /// again (so nothing written during the first run is missed). False when the round-trip failed —
    /// local data is already persisted and a later trigger retries.
    func sync(uid: String) async -> Bool {
        while let current = running { _ = await current.value }
        let task = Task { await self.performSync(uid: uid) }
        running = task
        let ok = await task.value
        if running == task { running = nil }
        return ok
    }

    /// Hard-deletes every local row (account switch / account deletion). The ONLY hard delete.
    func wipeLocal() {
        let ctx = ModelContext(modelContainer)
        try? ctx.delete(model: CollectionCopy.self)
        try? ctx.delete(model: WishlistItem.self)
        try? ctx.delete(model: Sale.self)
        try? ctx.save()
    }

    private func performSync(uid: String) async -> Bool {
        // PULL before push, each half isolated (its own catch) so a failure in one never skips the other —
        // a rejected push still lets the pull through, and vice versa. The round succeeds only when both
        // halves ran; the scheduler retries a failed one.
        var ok = true
        do { try await pull() } catch {
            ok = false
            Self.log.error("pull failed: \(String(describing: error))")
        }
        do { try await push(uid: uid) } catch {
            ok = false
            Self.log.error("push failed: \(String(describing: error))")
        }
        return ok
    }

    // MARK: Push (dirty local → Supabase upsert)

    /// The three tables push INDEPENDENTLY: a rejected batch in one must not skip the others. The first
    /// failure is rethrown at the end so the round still reports it.
    private func push(uid: String) async throws {
        var failures: [any Error] = []
        do {
            // Paid prices are published as community value points AFTER their rows land, so the
            // server-side owner-gate can see them.
            try await pushTable("collection_copies", CollectionCopy.self,
                                remote: { RemoteCopy($0, uid: uid) }, contribution: { Contribution(copy: $0) })
        } catch { failures.append(error) }
        do {
            try await pushTable("wishlist_items", WishlistItem.self,
                                remote: { RemoteWish($0, uid: uid) }, contribution: { _ in nil })
        } catch { failures.append(error) }
        do {
            // Contributed last so, when a user has both a paid copy and a sale of the same item, the
            // realized sale wins the single per-user point — it is the better signal.
            try await pushTable("sales", Sale.self,
                                remote: { RemoteSale($0, uid: uid) }, contribution: { Contribution(sale: $0) })
        } catch { failures.append(error) }
        if let first = failures.first { throw first }
    }

    private func pushTable<M: SyncableRow, R: RemoteRow>(
        _ table: String, _ type: M.Type,
        remote: (M) -> R?, contribution: (M) -> Contribution?
    ) async throws {
        let ctx = ModelContext(modelContainer)
        let dirty = try M.fetchDirty(in: ctx)
        guard !dirty.isEmpty else { return }
        // Snapshot everything the network half needs before awaiting.
        let rows = dirty.compactMap(remote)
        let stamps = dirty.map { Pushed(id: $0.id, updatedAt: $0.updatedAt) }
        let points = dirty.compactMap { row in contribution(row).map { (id: row.id, point: $0) } }

        let rejected = try await upsertRows(table, rows)
        // A REJECTED row stays dirty — never claimed as synced — and retries next round. A row with neither
        // set_id nor fig_num can't map to a remote row; it is still marked clean (it can never sync) so it
        // doesn't re-queue forever.
        try clearDirty(M.self, stamps.filter { !rejected.contains($0.id) })
        await contribute(points.filter { !rejected.contains($0.id) }.map { $0.point })
        if !rejected.isEmpty { throw PushRejected(table: table, ids: rejected) }
    }

    /// Upsert `rows` as one batch; if the server rejects the batch because of a ROW's content (one bad row
    /// fails the whole statement — see `SyncRules.isRowRejection`), fall back to one upsert per row so the
    /// good rows still land, and return the ids it rejected. Any other failure (offline, timeout, expired
    /// session, 5xx) is not retried row by row — it would fail every row for the same reason — and
    /// propagates, so the round counts as failed and the scheduler retries it.
    private func upsertRows<R: RemoteRow>(_ table: String, _ rows: [R]) async throws -> Set<String> {
        guard !rows.isEmpty else { return [] }
        do {
            try await client.from(table).upsert(rows, returning: .minimal).execute()
            return []
        } catch let error as PostgrestError where SyncRules.isRowRejection(sqlState: error.code) {
            Self.log.warning("\(table) batch rejected (\(error.code ?? "?")) — pushing row by row")
        }
        var rejected = Set<String>()
        for row in rows {
            do {
                try await client.from(table).upsert(row, returning: .minimal).execute()
            } catch let error as PostgrestError where SyncRules.isRowRejection(sqlState: error.code) {
                rejected.insert(row.id)
                Self.log.error("\(table) rejected row \(row.id): \(error.code ?? "?") \(error.message)")
            }
        }
        return rejected
    }

    private struct PushRejected: Error, CustomStringConvertible {
        let table: String
        let ids: Set<String>
        var description: String { "\(table): \(ids.count) row(s) rejected by the server (\(ids.sorted().joined(separator: ", ")))" }
    }

    private struct Pushed { var id: String; var updatedAt: Int64 }

    private func clearDirty<T: SyncableRow>(_ type: T.Type, _ pushed: [Pushed]) throws {
        let ctx = ModelContext(modelContainer)
        let stamps = Dictionary(pushed.map { ($0.id, $0.updatedAt) }, uniquingKeysWith: { a, _ in a })
        for chunk in Array(stamps.keys).chunked(500) {
            for row in try T.fetch(ids: chunk, in: ctx) where row.updatedAt == stamps[row.id] { row.dirty = false }
        }
        try ctx.save()
    }

    /// Best-effort and per-row guarded — a contribution failure must never abort the sync.
    private func contribute(_ points: [Contribution]) async {
        for p in points {
            do {
                try await client.rpc("contribute_value", params: p).execute()
            } catch {
                Self.log.warning("contribute_value failed: \(error.localizedDescription)")
            }
        }
    }

    // MARK: Pull (rows stamped after each table's cursor → local, LWW on the client updated_at)

    private func pull() async throws {
        if syncState.cursorVersion < SyncStateStore.currentCursorVersion {
            syncState.clearPullCursors()
            syncState.setCursorVersion(SyncStateStore.currentCursorVersion)
        }
        let copies: [RemoteCopy] = try await fetchTable("collection_copies")
        let wishes: [RemoteWish] = try await fetchTable("wishlist_items")
        let sales: [RemoteSale] = try await fetchTable("sales")
        guard !(copies.isEmpty && wishes.isEmpty && sales.isEmpty) else { return }

        // Rebuild each pulled row's denormalized display fields from the catalog — every referenced
        // set/fig across all three tables in ONE batch per kind. Tombstones need no display fields.
        let live: [any RemoteRow] = copies.filter { !$0.deleted } + wishes.filter { !$0.deleted } + sales.filter { !$0.deleted }
        let setIds = Set(live.compactMap(\.setId))
        let figNums = Set(live.compactMap(\.figNum))
        // A catalog failure THROWS (aborting the pull before any cursor advances) rather than skipping
        // rows: a skipped row behind an advanced cursor would never be fetched again.
        let sets = try await CatalogRepository.shared.fetchSets(ids: setIds)
            .reduce(into: [Int64: CatalogSet]()) { acc, s in if let id = s.setId { acc[id] = s } }
        let figs = try await CatalogRepository.shared.fetchMinifigs(figNums: figNums)
            .reduce(into: [String: Minifig]()) { $0[$1.figNum] = $1 }

        try apply(copies, table: "collection_copies", CollectionCopy.self) { r, d in
            CollectionCopy(
                id: r.id, setId: r.setId, figNum: r.figNum, itemKind: r.itemKind,
                setNumber: d.setNumber, name: d.name, theme: d.theme, subtheme: d.subtheme,
                releaseYear: d.releaseYear, releaseMonth: d.releaseMonth, pieces: d.pieces, minifigs: d.minifigs,
                retailPrice: d.retailPrice, status: d.status, imageUrl: d.imageUrl,
                quantity: r.quantity, condition: r.condition ?? "new",
                pricePaid: Int64((r.pricePaid ?? 0).rounded()), currency: r.currency ?? "USD",
                acquiredOn: r.acquiredOn, notes: r.notes,
                tombstoned: r.deleted, updatedAt: ISO8601.millis(r.updatedAt), dirty: false
            )
        } update: { row, r, d in
            row.setId = r.setId; row.figNum = r.figNum; row.itemKind = r.itemKind
            if let d {
                row.setNumber = d.setNumber; row.name = d.name; row.theme = d.theme; row.subtheme = d.subtheme
                row.releaseYear = d.releaseYear; row.releaseMonth = d.releaseMonth
                row.pieces = d.pieces; row.minifigs = d.minifigs
                row.retailPrice = d.retailPrice; row.status = d.status; row.imageUrl = d.imageUrl
            }
            row.quantity = r.quantity; row.condition = r.condition ?? "new"
            row.pricePaid = Int64((r.pricePaid ?? 0).rounded()); row.currency = r.currency ?? "USD"
            row.acquiredOn = r.acquiredOn; row.notes = r.notes
        } display: { Display(setId: $0.setId, figNum: $0.figNum, sets: sets, figs: figs) }

        let appliedWishes = try apply(wishes, table: "wishlist_items", WishlistItem.self) { r, d in
            WishlistItem(
                id: r.id, setId: r.setId, figNum: r.figNum, itemKind: r.itemKind,
                setNumber: d.setNumber, name: d.name, theme: d.theme, subtheme: d.subtheme,
                releaseYear: d.releaseYear, releaseMonth: d.releaseMonth, pieces: d.pieces, minifigs: d.minifigs,
                retailPrice: d.retailPrice, status: d.status, imageUrl: d.imageUrl,
                tombstoned: r.deleted, updatedAt: ISO8601.millis(r.updatedAt), dirty: false
            )
        } update: { row, r, d in
            row.setId = r.setId; row.figNum = r.figNum; row.itemKind = r.itemKind
            if let d {
                row.setNumber = d.setNumber; row.name = d.name; row.theme = d.theme; row.subtheme = d.subtheme
                row.releaseYear = d.releaseYear; row.releaseMonth = d.releaseMonth
                row.pieces = d.pieces; row.minifigs = d.minifigs
                row.retailPrice = d.retailPrice; row.status = d.status; row.imageUrl = d.imageUrl
            }
        } display: { Display(setId: $0.setId, figNum: $0.figNum, sets: sets, figs: figs) }
        try tombstoneWishlistDuplicates(of: wishes, applied: appliedWishes)

        try apply(sales, table: "sales", Sale.self) { r, d in
            Sale(
                id: r.id, setId: r.setId, figNum: r.figNum, itemKind: r.itemKind,
                setNumber: d.setNumber, name: d.name, theme: d.theme,
                releaseYear: d.releaseYear, releaseMonth: d.releaseMonth,
                imageUrl: d.imageUrl, retailPrice: d.retailPrice,
                quantity: r.quantity, condition: r.condition ?? "new",
                pricePaid: Int64((r.pricePaid ?? 0).rounded()), salePrice: Int64(r.salePrice.rounded()),
                currency: r.currency ?? "USD", soldOn: r.soldOn, notes: r.notes,
                tombstoned: r.deleted, updatedAt: ISO8601.millis(r.updatedAt), dirty: false
            )
        } update: { row, r, d in
            row.setId = r.setId; row.figNum = r.figNum; row.itemKind = r.itemKind
            if let d {
                row.setNumber = d.setNumber; row.name = d.name; row.theme = d.theme
                row.releaseYear = d.releaseYear; row.releaseMonth = d.releaseMonth
                row.imageUrl = d.imageUrl; row.retailPrice = d.retailPrice
            }
            row.quantity = r.quantity; row.condition = r.condition ?? "new"
            row.pricePaid = Int64((r.pricePaid ?? 0).rounded()); row.salePrice = Int64(r.salePrice.rounded())
            row.currency = r.currency ?? "USD"; row.soldOn = r.soldOn; row.notes = r.notes
        } display: { Display(setId: $0.setId, figNum: $0.figNum, sets: sets, figs: figs) }
    }

    /// Every row of one table past its cursor, **paged until drained** by keyset on
    /// (server_updated_at, id) — see `SyncRules.Cursor`: a bulk upsert stamps all its rows with ONE server
    /// time, and a stamp-only `>` cursor advanced past a capped page lost every sibling row at that stamp.
    /// Each page continues from the LAST ROW of the previous one (never an offset: a row re-stamped by
    /// another device mid-pull sorts to the end and would shift later rows, skipping one), until a short
    /// page; rows are then de-duplicated by id. The stored cursor advances only after the rows apply.
    private func fetchTable<T: RemoteRow>(_ table: String) async throws -> [T] {
        var cursor = SyncRules.Cursor.decode(syncState.pullCursor(table))
        var pages: [[T]] = []
        while true {
            var query = client.from(table).select()
            if let cursor {
                if let after = cursor.afterFilter {
                    query = query.or(after)
                } else {
                    query = query.gt("server_updated_at", value: cursor.stamp) // pre-keyset cursor
                }
            }
            let page: [T] = try await query
                .order("server_updated_at", ascending: true)
                .order("id", ascending: true)
                .limit(SyncRules.pullPageSize)
                .execute().value
            pages.append(page)
            guard !SyncRules.isLastPage(page.count), let last = page.last, let stamp = last.serverUpdatedAt else { break }
            cursor = SyncRules.Cursor(stamp: stamp, lastId: last.id)
        }
        return SyncRules.mergePages(pages) { $0.id }
    }

    /// LWW merge of one table's pulled rows (`SyncRules.remoteWins` — a strictly newer remote row
    /// replaces the local one even when it is dirty), then advance that table's cursor to the newest
    /// SERVER stamp + id received — never the client clock. Returns the ids actually applied.
    @discardableResult
    private func apply<R: RemoteRow, M: SyncableRow>(
        _ remote: [R], table: String, _ type: M.Type,
        insert: (R, Display) -> M,
        update: (M, R, Display?) -> Void,
        display: (R) -> Display?
    ) throws -> Set<String> {
        guard !remote.isEmpty else { return [] }
        let ctx = ModelContext(modelContainer)
        let ids = remote.map(\.id)
        var local: [String: M] = [:]
        for chunk in ids.chunked(500) {
            for row in try M.fetch(ids: chunk, in: ctx) { local[row.id] = row }
        }
        var applied = Set<String>()
        for r in remote {
            let remoteAt = ISO8601.millis(r.updatedAt)
            if let existing = local[r.id] {
                guard SyncRules.remoteWins(local: existing.updatedAt, remote: remoteAt) else { continue }
                update(existing, r, r.deleted ? nil : display(r))
                existing.tombstoned = r.deleted
                existing.updatedAt = remoteAt
                existing.dirty = false
                applied.insert(r.id)
            } else {
                // A tombstone for a row this device never had needs no local record.
                guard !r.deleted, let d = display(r) else { continue }
                let row = insert(r, d)
                ctx.insert(row)
                local[r.id] = row
                applied.insert(r.id)
            }
        }
        try ctx.save()
        if let next = SyncRules.nextCursor(remote, stamp: { $0.serverUpdatedAt }, id: { $0.id }) {
            syncState.setPullCursor(table, next.encoded)
        }
        return applied
    }

    /// The server allows ONE live wishlist row per user per item. If this device minted its own row for
    /// an item another device already synced (both wishlisted it offline), the local row would violate
    /// the unique index on every push, forever. The remote row is the one the server holds, so it
    /// survives; the local duplicate is tombstoned (dirty, so the tombstone pushes — deleted rows are
    /// outside the partial index). Only rows this pull actually applied count as survivors.
    private func tombstoneWishlistDuplicates(of remote: [RemoteWish], applied: Set<String>) throws {
        let survivors = remote.filter { !$0.deleted && applied.contains($0.id) }
        guard !survivors.isEmpty else { return }
        let ctx = ModelContext(modelContainer)
        let active = try WishlistItem.fetchActive(in: ctx)
        let refs = active.map { SyncRules.RowRef(id: $0.id, setId: $0.setId, figNum: $0.figNum) }
        var doomed = Set<String>()
        for r in survivors {
            doomed.formUnion(SyncRules.wishlistDuplicates(refs, keep: .init(id: r.id, setId: r.setId, figNum: r.figNum)))
        }
        guard !doomed.isEmpty else { return }
        let now = Int64((Date().timeIntervalSince1970 * 1000).rounded())
        for row in active where doomed.contains(row.id) {
            row.tombstoned = true
            row.updatedAt = now
            row.dirty = true
        }
        try ctx.save()
    }
}

// MARK: - Display-field reconstruction

/// The denormalized catalog fields for a pulled row, rebuilt from the set OR the minifig catalog
/// (polymorphic). nil when the item no longer exists in the catalog.
private struct Display {
    var setNumber: String
    var name: String
    var theme: String
    var subtheme: String
    var releaseYear: Int
    var releaseMonth: Int
    var pieces: Int
    var minifigs: Int
    var retailPrice: Int64?
    var status: String
    var imageUrl: String?

    init?(setId: Int64?, figNum: String?, sets: [Int64: CatalogSet], figs: [String: Minifig]) {
        if let set = setId.flatMap({ sets[$0] }) {
            setNumber = set.setNumber; name = set.name; theme = set.theme; subtheme = set.subtheme
            releaseYear = set.releaseYear; releaseMonth = set.releaseMonth
            pieces = set.pieces; minifigs = set.minifigs
            retailPrice = set.retailPrice; status = set.status.rawValue
            // Rows persist the small thumb; the gallery recovers the render via CatalogImages.renderFromThumb.
            imageUrl = set.thumbnailUrl ?? set.imageUrl
        } else if let figNum {
            // A minifig missing from the catalog still renders, keyed by its fig_num.
            let fig = figs[figNum]
            setNumber = figNum; name = fig?.name ?? figNum; theme = fig?.themes.first ?? ""; subtheme = "General"
            releaseYear = 0; releaseMonth = 0; pieces = fig?.numParts ?? 0; minifigs = 0
            retailPrice = nil; status = Availability.available.rawValue; imageUrl = fig?.imageUrl
        } else {
            return nil
        }
    }
}

// MARK: - Remote DTOs

private protocol RemoteRow: Codable, Sendable {
    var id: String { get }
    var setId: Int64? { get }
    var figNum: String? { get }
    var deleted: Bool { get }
    var updatedAt: String { get }
    var serverUpdatedAt: String? { get }
}

/*
 * Encoding notes (both are required, not cosmetic):
 *  - EVERY key is always written, nulls included. PostgREST builds a bulk upsert's column list from
 *    the UNION of keys across the batch, and a column absent from the whole batch is left untouched on
 *    conflict — so an omitted nil would (a) write NULL into a NOT NULL column for a row that skipped a
 *    defaulted key, or (b) fail to clear a note the user just deleted.
 *  - `server_updated_at` is never sent: the BEFORE trigger stamps it server-side.
 */

private struct RemoteCopy: RemoteRow {
    var id: String
    var userId: String?
    var setId: Int64?
    var figNum: String?
    var itemKind: String
    var quantity: Int
    var condition: String?
    var pricePaid: Double?
    var currency: String?
    var acquiredOn: String?
    var notes: String?
    var deleted: Bool
    var updatedAt: String
    var serverUpdatedAt: String?

    enum CodingKeys: String, CodingKey {
        case id, userId = "user_id", setId = "set_id", figNum = "fig_num", itemKind = "item_kind"
        case quantity, condition, pricePaid = "price_paid", currency, acquiredOn = "acquired_on", notes
        case deleted, updatedAt = "updated_at", serverUpdatedAt = "server_updated_at"
    }

    init?(_ row: CollectionCopy, uid: String) {
        guard row.setId != nil || row.figNum != nil else { return nil }
        id = row.id; userId = uid; setId = row.setId; figNum = row.figNum; itemKind = row.itemKind
        quantity = row.quantity; condition = row.condition; pricePaid = Double(row.pricePaid)
        currency = row.currency; acquiredOn = row.acquiredOn; notes = row.notes
        deleted = row.tombstoned; updatedAt = ISO8601.string(millis: row.updatedAt)
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        userId = try c.decodeIfPresent(String.self, forKey: .userId)
        setId = try c.decodeIfPresent(Int64.self, forKey: .setId)
        figNum = try c.decodeIfPresent(String.self, forKey: .figNum)
        itemKind = try c.decodeIfPresent(String.self, forKey: .itemKind) ?? "set"
        quantity = try c.decodeIfPresent(Int.self, forKey: .quantity) ?? 1
        condition = try c.decodeIfPresent(String.self, forKey: .condition)
        pricePaid = try c.decodeIfPresent(Double.self, forKey: .pricePaid)
        currency = try c.decodeIfPresent(String.self, forKey: .currency)
        acquiredOn = try c.decodeIfPresent(String.self, forKey: .acquiredOn)
        notes = try c.decodeIfPresent(String.self, forKey: .notes)
        deleted = try c.decodeIfPresent(Bool.self, forKey: .deleted) ?? false
        updatedAt = try c.decode(String.self, forKey: .updatedAt)
        serverUpdatedAt = try c.decodeIfPresent(String.self, forKey: .serverUpdatedAt)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(userId, forKey: .userId)
        try c.encode(setId, forKey: .setId)
        try c.encode(figNum, forKey: .figNum)
        try c.encode(itemKind, forKey: .itemKind)
        try c.encode(quantity, forKey: .quantity)
        try c.encode(condition, forKey: .condition)
        try c.encode(pricePaid, forKey: .pricePaid)
        try c.encode(currency, forKey: .currency)
        try c.encode(acquiredOn, forKey: .acquiredOn)
        try c.encode(notes, forKey: .notes)
        try c.encode(deleted, forKey: .deleted)
        try c.encode(updatedAt, forKey: .updatedAt)
    }
}

private struct RemoteWish: RemoteRow {
    var id: String
    var userId: String?
    var setId: Int64?
    var figNum: String?
    var itemKind: String
    var deleted: Bool
    var updatedAt: String
    var serverUpdatedAt: String?

    enum CodingKeys: String, CodingKey {
        case id, userId = "user_id", setId = "set_id", figNum = "fig_num", itemKind = "item_kind"
        case deleted, updatedAt = "updated_at", serverUpdatedAt = "server_updated_at"
    }

    init?(_ row: WishlistItem, uid: String) {
        guard row.setId != nil || row.figNum != nil else { return nil }
        id = row.id; userId = uid; setId = row.setId; figNum = row.figNum; itemKind = row.itemKind
        deleted = row.tombstoned; updatedAt = ISO8601.string(millis: row.updatedAt)
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        userId = try c.decodeIfPresent(String.self, forKey: .userId)
        setId = try c.decodeIfPresent(Int64.self, forKey: .setId)
        figNum = try c.decodeIfPresent(String.self, forKey: .figNum)
        itemKind = try c.decodeIfPresent(String.self, forKey: .itemKind) ?? "set"
        deleted = try c.decodeIfPresent(Bool.self, forKey: .deleted) ?? false
        updatedAt = try c.decode(String.self, forKey: .updatedAt)
        serverUpdatedAt = try c.decodeIfPresent(String.self, forKey: .serverUpdatedAt)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(userId, forKey: .userId)
        try c.encode(setId, forKey: .setId)
        try c.encode(figNum, forKey: .figNum)
        try c.encode(itemKind, forKey: .itemKind)
        try c.encode(deleted, forKey: .deleted)
        try c.encode(updatedAt, forKey: .updatedAt)
    }
}

private struct RemoteSale: RemoteRow {
    var id: String
    var userId: String?
    var setId: Int64?
    var figNum: String?
    var itemKind: String
    var quantity: Int
    var condition: String?
    var pricePaid: Double?
    var salePrice: Double
    var currency: String?
    var soldOn: String?
    var notes: String?
    var deleted: Bool
    var updatedAt: String
    var serverUpdatedAt: String?

    enum CodingKeys: String, CodingKey {
        case id, userId = "user_id", setId = "set_id", figNum = "fig_num", itemKind = "item_kind"
        case quantity, condition, pricePaid = "price_paid", salePrice = "sale_price", currency
        case soldOn = "sold_on", notes, deleted, updatedAt = "updated_at", serverUpdatedAt = "server_updated_at"
    }

    init?(_ row: Sale, uid: String) {
        guard row.setId != nil || row.figNum != nil else { return nil }
        id = row.id; userId = uid; setId = row.setId; figNum = row.figNum; itemKind = row.itemKind
        quantity = row.quantity; condition = row.condition
        pricePaid = Double(row.pricePaid); salePrice = Double(row.salePrice)
        currency = row.currency; soldOn = row.soldOn; notes = row.notes
        deleted = row.tombstoned; updatedAt = ISO8601.string(millis: row.updatedAt)
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        userId = try c.decodeIfPresent(String.self, forKey: .userId)
        setId = try c.decodeIfPresent(Int64.self, forKey: .setId)
        figNum = try c.decodeIfPresent(String.self, forKey: .figNum)
        itemKind = try c.decodeIfPresent(String.self, forKey: .itemKind) ?? "set"
        quantity = try c.decodeIfPresent(Int.self, forKey: .quantity) ?? 1
        condition = try c.decodeIfPresent(String.self, forKey: .condition)
        pricePaid = try c.decodeIfPresent(Double.self, forKey: .pricePaid)
        salePrice = try c.decodeIfPresent(Double.self, forKey: .salePrice) ?? 0
        currency = try c.decodeIfPresent(String.self, forKey: .currency)
        soldOn = try c.decodeIfPresent(String.self, forKey: .soldOn)
        notes = try c.decodeIfPresent(String.self, forKey: .notes)
        deleted = try c.decodeIfPresent(Bool.self, forKey: .deleted) ?? false
        updatedAt = try c.decode(String.self, forKey: .updatedAt)
        serverUpdatedAt = try c.decodeIfPresent(String.self, forKey: .serverUpdatedAt)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(userId, forKey: .userId)
        try c.encode(setId, forKey: .setId)
        try c.encode(figNum, forKey: .figNum)
        try c.encode(itemKind, forKey: .itemKind)
        try c.encode(quantity, forKey: .quantity)
        try c.encode(condition, forKey: .condition)
        try c.encode(pricePaid, forKey: .pricePaid)
        try c.encode(salePrice, forKey: .salePrice)
        try c.encode(currency, forKey: .currency)
        try c.encode(soldOn, forKey: .soldOn)
        try c.encode(notes, forKey: .notes)
        try c.encode(deleted, forKey: .deleted)
        try c.encode(updatedAt, forKey: .updatedAt)
    }
}

/// `contribute_value` RPC args, passed BY NAME. Exactly one of set_id / fig_num is sent.
private struct Contribution: Encodable, Sendable {
    var setId: Int64?
    var figNum: String?
    var value: Int64
    var currency: String
    var source: String

    enum CodingKeys: String, CodingKey {
        case setId = "p_set_id", figNum = "p_fig_num", value = "p_value", currency = "p_currency", source = "p_source"
    }

    init?(copy: CollectionCopy) {
        guard !copy.tombstoned, copy.pricePaid > 0, (copy.setId == nil) != (copy.figNum == nil) else { return nil }
        setId = copy.setId; figNum = copy.figNum; value = copy.pricePaid; currency = copy.currency; source = "paid"
    }

    init?(sale: Sale) {
        guard !sale.tombstoned, sale.salePrice > 0, (sale.setId == nil) != (sale.figNum == nil) else { return nil }
        setId = sale.setId; figNum = sale.figNum; value = sale.salePrice; currency = sale.currency; source = "sale"
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encodeIfPresent(setId, forKey: .setId)
        try c.encodeIfPresent(figNum, forKey: .figNum)
        try c.encode(value, forKey: .value)
        try c.encode(currency, forKey: .currency)
        try c.encode(source, forKey: .source)
    }
}
