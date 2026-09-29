import Foundation

/// Persisted sync state (UserDefaults — the DataStore analog): `lastAccountId` backs the
/// account-switch guard, and the per-table **pull cursors** hold the newest SERVER
/// `server_updated_at` stamp received for each user-data table. One cursor per table, so a capped
/// page in one table can't be skipped past by a later stamp from another.
struct SyncStateStore: Sendable {
    static let tables = ["collection_copies", "wishlist_items", "sales"]
    /// 2 = per-table server stamp (Android's cursor version 2); 3 = keyset `stamp|id` cursors. Raising it
    /// clears every cursor once, so the first pull after upgrading re-fetches everything and heals any rows
    /// the stamp-only paging skipped. Idempotent: LWW keeps anything local that is as new or newer.
    static let currentCursorVersion = 3

    private enum Key {
        static let lastAccountId = "sync.last_account_id"
        static let cursorVersion = "sync.cursor_version"
        static func pullCursor(_ table: String) -> String { "sync.pull_cursor_\(table)" }
    }

    private var defaults: UserDefaults { .standard }

    var lastAccountId: String? { defaults.string(forKey: Key.lastAccountId) }
    func setLastAccountId(_ id: String?) { defaults.set(id, forKey: Key.lastAccountId) }

    /// `table`'s encoded `SyncRules.Cursor` (newest `server_updated_at` received + greatest id at it), or
    /// nil = never pulled (fetch everything).
    func pullCursor(_ table: String) -> String? { defaults.string(forKey: Key.pullCursor(table)) }
    func setPullCursor(_ table: String, _ cursor: String) { defaults.set(cursor, forKey: Key.pullCursor(table)) }

    /// Drops every table's cursor so the next sync re-pulls everything (account switch / upgrade).
    func clearPullCursors() {
        Self.tables.forEach { defaults.removeObject(forKey: Key.pullCursor($0)) }
    }

    var cursorVersion: Int {
        if defaults.object(forKey: Key.cursorVersion) != nil { return defaults.integer(forKey: Key.cursorVersion) }
        // Never recorded: v2 didn't persist its version, so existing cursors are the v2 stamp-only format;
        // a store with no cursors (fresh install, or just wiped) has nothing to migrate.
        return Self.tables.contains { pullCursor($0) != nil } ? 2 : Self.currentCursorVersion
    }
    func setCursorVersion(_ v: Int) { defaults.set(v, forKey: Key.cursorVersion) }

    /// Account deletion: forget the account + all cursors.
    func reset() {
        clearPullCursors()
        defaults.removeObject(forKey: Key.lastAccountId)
    }
}
