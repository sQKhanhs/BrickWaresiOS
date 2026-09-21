import Foundation

/// Persisted sync state (UserDefaults — the DataStore analog): `lastAccountId` backs the
/// account-switch guard, and the per-table **pull cursors** hold the newest SERVER
/// `server_updated_at` stamp received for each user-data table. One cursor per table, so a capped
/// page in one table can't be skipped past by a later stamp from another.
struct SyncStateStore: Sendable {
    static let tables = ["collection_copies", "wishlist_items", "sales"]
    /// iOS starts on the per-table server-stamp scheme (Android's cursor version 2).
    static let currentCursorVersion = 2

    private enum Key {
        static let lastAccountId = "sync.last_account_id"
        static let cursorVersion = "sync.cursor_version"
        static func pullCursor(_ table: String) -> String { "sync.pull_cursor_\(table)" }
    }

    private var defaults: UserDefaults { .standard }

    var lastAccountId: String? { defaults.string(forKey: Key.lastAccountId) }
    func setLastAccountId(_ id: String?) { defaults.set(id, forKey: Key.lastAccountId) }

    /// Newest `server_updated_at` received for `table`, or nil = never pulled (fetch everything).
    func pullCursor(_ table: String) -> String? { defaults.string(forKey: Key.pullCursor(table)) }
    func setPullCursor(_ table: String, _ stamp: String) { defaults.set(stamp, forKey: Key.pullCursor(table)) }

    /// Drops every table's cursor so the next sync re-pulls everything (account switch / upgrade).
    func clearPullCursors() {
        Self.tables.forEach { defaults.removeObject(forKey: Key.pullCursor($0)) }
    }

    var cursorVersion: Int {
        defaults.object(forKey: Key.cursorVersion) == nil ? Self.currentCursorVersion : defaults.integer(forKey: Key.cursorVersion)
    }
    func setCursorVersion(_ v: Int) { defaults.set(v, forKey: Key.cursorVersion) }

    /// Account deletion: forget the account + all cursors.
    func reset() {
        clearPullCursors()
        defaults.removeObject(forKey: Key.lastAccountId)
    }
}
