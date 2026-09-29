import Foundation
import SwiftData
import Testing
@testable import BrickWares

// Parity with Android's SyncRulesTest / UserDataLimitsTest: the conflict, paging and cap rules the sync
// engine and write funnel call. A divergence here means two devices resolve the same rows differently.

struct SyncRulesTests {
    // MARK: Cursor

    @Test func cursorRoundTripsAndReadsLegacyBareStamps() {
        let c = SyncRules.Cursor(stamp: "2026-09-23T10:00:00.123456+00:00", lastId: "0f0e-uuid")
        #expect(SyncRules.Cursor.decode(c.encoded) == c)
        // A pre-keyset cursor is a bare stamp: no id, resumes with `stamp > s`.
        #expect(SyncRules.Cursor.decode("2026-09-23T10:00:00+00:00") == .init(stamp: "2026-09-23T10:00:00+00:00", lastId: nil))
        #expect(SyncRules.Cursor.decode("2026-09-23T10:00:00+00:00|")?.lastId == nil)
        #expect(SyncRules.Cursor.decode(nil) == nil)
        #expect(SyncRules.Cursor.decode("") == nil)
    }

    @Test func keysetFilterQuotesReservedCharacters() {
        let c = SyncRules.Cursor(stamp: "2026-09-23T10:00:00.5+00:00", lastId: "abc")
        #expect(c.afterFilter ==
            #"server_updated_at.gt."2026-09-23T10:00:00.5+00:00",and(server_updated_at.eq."2026-09-23T10:00:00.5+00:00",id.gt."abc")"#)
        #expect(SyncRules.Cursor(stamp: "x", lastId: nil).afterFilter == nil)
    }

    // MARK: LWW

    @Test func remoteWinsOnlyWhenStrictlyNewer() {
        #expect(SyncRules.remoteWins(local: nil, remote: 0))      // nothing local
        #expect(SyncRules.remoteWins(local: 100, remote: 101))    // newer remote beats even a dirty local
        #expect(!SyncRules.remoteWins(local: 101, remote: 100))   // stale remote never overwrites
        #expect(!SyncRules.remoteWins(local: 100, remote: 100))   // tie keeps local
        #expect(!SyncRules.remoteWins(local: 100, remote: 0))     // unparseable remote stamp (0) never wins
    }

    // MARK: Paging

    @Test func lastPageAndMerge() {
        #expect(SyncRules.isLastPage(499))
        #expect(!SyncRules.isLastPage(500))
        // A row re-stamped mid-pull appears on two pages: keep its LAST version, at its first position.
        let pages = [[("a", 1), ("b", 1)], [("c", 1), ("a", 2)]]
        let merged = SyncRules.mergePages(pages) { $0.0 }
        #expect(merged.map { $0.0 } == ["a", "b", "c"])
        #expect(merged.first?.1 == 2)
    }

    @Test func nextCursorIsNewestStampAtMicrosecondPrecisionThenGreatestId() {
        struct Row { var id: String; var stamp: String? }
        // Same millisecond, different microseconds, and a trimmed-zero fraction: .1657 < .165753.
        let rows = [
            Row(id: "f", stamp: "2026-09-23T10:00:00.165753+00:00"),
            Row(id: "z", stamp: "2026-09-23T10:00:00.1657+00:00"),
            Row(id: "a", stamp: "2026-09-23T10:00:00.165753+00:00"),
            Row(id: "q", stamp: nil),
            Row(id: "r", stamp: "garbage"),
        ]
        let c = SyncRules.nextCursor(rows, stamp: { $0.stamp }, id: { $0.id })
        #expect(c == .init(stamp: "2026-09-23T10:00:00.165753+00:00", lastId: "f"))
        #expect(SyncRules.nextCursor([Row](), stamp: { $0.stamp }, id: { $0.id }) == nil)
        #expect(SyncRules.nextCursor([Row(id: "x", stamp: nil)], stamp: { $0.stamp }, id: { $0.id }) == nil)
    }

    // MARK: Wishlist duplicates

    @Test func wishlistDuplicatesKeepTheServerRow() {
        typealias R = SyncRules.RowRef
        let active = [
            R(id: "server", setId: 10, figNum: nil),
            R(id: "mine", setId: 10, figNum: nil),     // same set, minted offline here → duplicate
            R(id: "other", setId: 11, figNum: nil),    // different set
            R(id: "fig", setId: nil, figNum: "fig-001"),
        ]
        #expect(SyncRules.wishlistDuplicates(active, keep: R(id: "server", setId: 10, figNum: nil)) == ["mine"])
        #expect(SyncRules.wishlistDuplicates(active, keep: R(id: "remoteFig", setId: nil, figNum: "fig-001")) == ["fig"])
        #expect(SyncRules.wishlistDuplicates(active, keep: R(id: "x", setId: 99, figNum: nil)).isEmpty)
    }

    // MARK: Push rejection

    @Test func onlyRowContentErrorsAreRowRejections() {
        for code in ["23505", "23514", "23503", "23502", "22001", "22003", "22P02"] {
            #expect(SyncRules.isRowRejection(sqlState: code), "\(code)")
        }
        for code in ["42501", "PGRST204", "PGRST301", "08006", "57014"] {
            #expect(!SyncRules.isRowRejection(sqlState: code), "\(code)")
        }
        #expect(!SyncRules.isRowRejection(sqlState: nil))
    }

    // MARK: Timestamps

    @Test func microsReadEveryPostgrestFractionWidth() {
        let base = ISO8601.micros("2026-09-23T10:00:00Z")!
        #expect(ISO8601.micros("2026-09-23T10:00:00+00:00") == base)
        #expect(ISO8601.micros("2026-09-23T10:00:00.5+00:00") == base + 500_000)
        #expect(ISO8601.micros("2026-09-23T10:00:00.165+00:00") == base + 165_000)
        #expect(ISO8601.micros("2026-09-23T10:00:00.165753+00:00") == base + 165_753)
        #expect(ISO8601.micros("2026-09-23T17:00:00.000001+07:00") == base + 1) // same instant, other offset
        #expect(ISO8601.micros("2026-09-23") == nil)
        #expect(ISO8601.micros("nonsense") == nil)
        #expect(ISO8601.millis("2026-09-23T10:00:00.165753+00:00") == base / 1000 + 165) // truncated like Android
    }
}

struct UserDataLimitsTests {
    @Test func capsMatchTheServerChecks() {
        #expect(UserDataLimits.capQty(0) == 1)
        #expect(UserDataLimits.capQty(-3) == 1)
        #expect(UserDataLimits.capQty(9999) == 9999)
        #expect(UserDataLimits.capQty(10_000) == 9999)
        #expect(UserDataLimits.capPrice(-1) == 0)
        #expect(UserDataLimits.capPrice(1_000_000_000_001) == 1_000_000_000_000)
        #expect(UserDataLimits.capNote(nil) == nil)
        #expect(UserDataLimits.capNote("short") == "short")
        #expect(UserDataLimits.capNote(String(repeating: "a", count: 2500))?.count == 2000)
    }

    @Test func noteCapCountsCodePointsLikePostgres() {
        // 👍🏽 is ONE Character but TWO code points; Postgres char_length counts code points.
        let note = String(repeating: "👍🏽", count: 1500) // 3000 code points
        let capped = UserDataLimits.capNote(note)!
        #expect(capped.unicodeScalars.count == 2000)
    }

    @Test func mergeRefusedPastQuantityCap() {
        #expect(UserDataLimits.canMergeQty(existing: 9998, added: 1))
        #expect(!UserDataLimits.canMergeQty(existing: 9998, added: 2))
        #expect(!UserDataLimits.canMergeQty(existing: 5, added: 0))
    }
}

/// The caps applied through the real write funnel (in-memory store).
@MainActor
struct WriteLimitsTests {
    private func makeService() throws -> (CollectionService, ModelContext) {
        let container = try UserDataStore.makeContainer(inMemory: true)
        return (CollectionService(container: container, sync: SyncScheduler(container: container)), container.mainContext)
    }

    private let falcon = CatalogSet(
        setNumber: "75192", name: "Falcon", theme: "Star Wars", releaseYear: 2017, releaseMonth: 10,
        pieces: 7541, minifigs: 8, retailPrice: 84_999, status: .available, setId: 1
    )

    @Test func addClampsQuantityPriceAndNote() throws {
        let (service, ctx) = try makeService()
        service.addCopy(of: falcon, .init(qty: 50_000, pricePaid: 5_000_000_000_000, note: String(repeating: "n", count: 2100)))
        let row = try #require(try CollectionCopy.fetchActive(in: ctx).first)
        #expect(row.quantity == 9999)
        #expect(row.pricePaid == UserDataLimits.maxPriceMinor)
        #expect(row.notes?.count == 2000)
    }

    @Test func identicalCopyPastTheCapAddsARowInsteadOfMerging() throws {
        let (service, ctx) = try makeService()
        service.addCopy(of: falcon, .init(qty: 9998, pricePaid: 9998))
        service.addCopy(of: falcon, .init(qty: 2, pricePaid: 2)) // same per-unit price, but 10,000 > cap
        let rows = try CollectionCopy.fetchActive(in: ctx).sorted { $0.quantity > $1.quantity }
        #expect(rows.map(\.quantity) == [9998, 2]) // no units or money dropped
        #expect(rows.map(\.pricePaid).reduce(0, +) == 10_000)
    }

    @Test func saleClampsAndRefusesAnOverCapMerge() throws {
        let (service, ctx) = try makeService()
        service.addSale(of: falcon, qty: 9999, condition: .new, paid: 9999, salePrice: 19_998, currency: .usd, soldOn: nil, note: nil)
        service.addSale(of: falcon, qty: 1, condition: .new, paid: 1, salePrice: 2, currency: .usd, soldOn: nil, note: nil)
        let rows = try Sale.fetchActive(in: ctx)
        #expect(rows.count == 2)
        #expect(rows.allSatisfy { $0.quantity <= UserDataLimits.maxQuantity })
    }
}
