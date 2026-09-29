import Foundation

/// The pure decision rules behind `SyncEngine` — no SwiftData, no network — ported from Android's
/// `SyncRules` so the conflict, paging and cursor logic is unit-testable and matches it exactly. The
/// engine owns the I/O; everything that decides *what* to do with a row or a page lives here.
enum SyncRules {
    /// Rows per pull page. Below PostgREST's `max_rows` (1000) so a page is never silently cut short.
    static let pullPageSize = 500

    /// Bounded backoff after a failed sync while online: the reconnect edge can fire a beat before the
    /// network actually routes, and one failed attempt would strand dirty rows until the next write.
    static let retryDelays: [Duration] = [.seconds(2), .seconds(8), .seconds(30)]

    /// A table's pull position: the newest SERVER stamp applied plus the greatest row id AT that stamp,
    /// so the next pull resumes with `stamp > s OR (stamp = s AND id > lastId)`. Keyset paging on
    /// (server_updated_at, id) is what makes a batch of rows sharing ONE stamp (a bulk upsert stamps them
    /// all with its transaction's `now()`) safe to split across pages — a stamp-only `>` cursor skipped
    /// every sibling past the page boundary. Encoded `stamp|lastId`; a bare stamp (the pre-keyset format)
    /// decodes with no id and resumes with `stamp > s`.
    struct Cursor: Equatable, Sendable {
        var stamp: String
        var lastId: String?

        var encoded: String { lastId.map { "\(stamp)|\($0)" } ?? stamp }

        static func decode(_ raw: String?) -> Cursor? {
            guard let raw, !raw.isEmpty else { return nil }
            guard let bar = raw.firstIndex(of: "|") else { return Cursor(stamp: raw, lastId: nil) }
            let id = String(raw[raw.index(after: bar)...])
            return Cursor(stamp: String(raw[..<bar]), lastId: id.isEmpty ? nil : id)
        }

        /// The PostgREST `or=(…)` body for "strictly after this cursor", or nil for a bare-stamp cursor
        /// (the caller then filters `server_updated_at > stamp`). Values are double-quoted: a timestamp
        /// contains `.` and `:`, which are reserved inside an `or` expression.
        var afterFilter: String? {
            guard let lastId else { return nil }
            let s = SyncRules.quoted(stamp), i = SyncRules.quoted(lastId)
            return "server_updated_at.gt.\(s),and(server_updated_at.eq.\(s),id.gt.\(i))"
        }
    }

    /// Last-writer-wins on the CLIENT `updated_at`: a remote row replaces the local one only when it is
    /// strictly newer — even over a dirty (unpushed) local edit, so another device's newer edit or delete
    /// supersedes a stale offline edit instead of being blocked by the dirty flag. (The server's
    /// `reject_stale_update` trigger would silently drop that stale edit on push anyway, leaving this
    /// device diverged.) A newer-or-equal local edit keeps winning and is pushed; ties keep local.
    static func remoteWins(local: Int64?, remote: Int64) -> Bool {
        guard let local else { return true }
        return remote > local
    }

    /// A page shorter than the page size is the last one.
    static func isLastPage(_ received: Int, pageSize: Int = pullPageSize) -> Bool { received < pageSize }

    /// Flatten pulled pages, de-duplicated by id: a row re-stamped mid-pull shows up on two pages and
    /// keeps its LAST version (at its first position).
    static func mergePages<T>(_ pages: [[T]], id: (T) -> String) -> [T] {
        var order: [String] = []
        var byId: [String: T] = [:]
        for page in pages {
            for row in page {
                let key = id(row)
                if byId.updateValue(row, forKey: key) == nil { order.append(key) }
            }
        }
        return order.compactMap { byId[$0] }
    }

    /// The cursor to store after `rows` apply: the newest server stamp — compared at Postgres' full
    /// microsecond precision — and, of the rows AT that stamp, the greatest id (lowercase uuid text order
    /// = Postgres uuid order). Nil when no row carries a parseable stamp; the caller then leaves the
    /// cursor untouched.
    static func nextCursor<T>(_ rows: [T], stamp: (T) -> String?, id: (T) -> String) -> Cursor? {
        var best: (micros: Int64, stamp: String, id: String)?
        for row in rows {
            guard let s = stamp(row), let us = ISO8601.micros(s) else { continue }
            let rowId = id(row)
            if let b = best, us < b.micros || (us == b.micros && rowId <= b.id) { continue }
            best = (us, s, rowId)
        }
        return best.map { Cursor(stamp: $0.stamp, lastId: $0.id) }
    }

    /// The polymorphic reference of a wishlist row (set_id XOR fig_num).
    struct RowRef: Equatable, Sendable {
        var id: String
        var setId: Int64?
        var figNum: String?
    }

    /// Which local ACTIVE wishlist rows duplicate an incoming live remote row (`keep`) for the same item
    /// and must be tombstoned. The server allows ONE live wishlist row per user per item (a partial
    /// unique index); two devices wishlisting the same item offline each mint their own id, the first to
    /// push wins, and the other device's row would violate the index on every push, forever. The row
    /// already on the server survives.
    static func wishlistDuplicates(_ active: [RowRef], keep: RowRef) -> [String] {
        active.filter { row in
            row.id != keep.id
                && ((keep.setId != nil && row.setId == keep.setId) || (keep.figNum != nil && row.figNum == keep.figNum))
        }.map(\.id)
    }

    /// Whether a push failure was caused by the ROW itself: a Postgres data exception (SQLSTATE class 22 —
    /// too long, out of range…) or integrity violation (class 23 — CHECK, unique, FK, not-null). Retrying
    /// such a batch row by row lets the good rows land. Anything else — offline, a timeout, an expired
    /// session, a 5xx, a PostgREST schema error — would fail every row for the same reason, so it
    /// propagates and the whole sync is retried on the backoff.
    static func isRowRejection(sqlState code: String?) -> Bool {
        guard let code else { return false }
        return code.hasPrefix("22") || code.hasPrefix("23")
    }

    /// Double-quote a value for use inside a PostgREST `or=(…)` / `and(…)` expression.
    static func quoted(_ v: String) -> String {
        "\"" + v.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }
}

/// The server-side CHECK constraints on the user-data tables (migration `20260922120000_hardening`),
/// mirrored on the client (Android `UserDataLimits`) so no dirty row can ever violate them: a row past
/// any cap is rejected by the server and stays dirty. Every write path — add, edit, merge, sell, CSV
/// import — clamps through here BEFORE the row is marked dirty.
enum UserDataLimits {
    /// `notes` length cap. Postgres `char_length` counts code points, so this is in Unicode scalars.
    static let maxNoteChars = 2000
    /// `quantity between 0 and 9999`; the client never stores 0 (an empty copy is tombstoned instead).
    static let maxQuantity = 9999
    /// `price >= 0 and <= 1e12` — in the row's own minor unit (USD cents / whole ₫).
    static let maxPriceMinor: Int64 = 1_000_000_000_000

    static func capNote(_ note: String?) -> String? {
        guard let note, note.unicodeScalars.count > maxNoteChars else { return note }
        return String(String.UnicodeScalarView(note.unicodeScalars.prefix(maxNoteChars)))
    }

    /// Clamp a stored quantity to the valid server range [1, `maxQuantity`].
    static func capQty(_ quantity: Int) -> Int { min(max(quantity, 1), maxQuantity) }

    /// Clamp a price (paid or sale, the row's total) to [0, `maxPriceMinor`].
    static func capPrice(_ amount: Int64) -> Int64 { min(max(amount, 0), maxPriceMinor) }

    /// Whether an identical copy/sale of `added` units may MERGE into an existing row of `existing`
    /// units. Past the cap the merge is refused (the caller inserts a fresh row for the new units) rather
    /// than clamped — clamping would keep the summed money but drop units, silently losing data.
    static func canMergeQty(existing: Int, added: Int) -> Bool { added >= 1 && existing + added <= maxQuantity }
}
