import Foundation
import SwiftData
import Testing
@testable import BrickWares

// Pure-logic parity tests: these pin the behaviors that must match the Android app exactly, because a
// divergence would show different numbers for the same data or corrupt a cross-platform CSV/sync.

struct MoneyTests {
    @Test func formatsLikeAndroid() {
        #expect(Money.formatIn(348_502, .usd) == "$3,485.02")
        #expect(Money.formatIn(-692, .usd) == "-$6.92")
        #expect(Money.formatIn(0, .usd) == "$0.00")
        #expect(Money.formatIn(90_608_440, .vnd) == "90.608.440₫")
        #expect(Money.formatIn(500, .vnd) == "500₫")
    }

    @Test func sameCurrencyIsExact() {
        // Identity when equal — a ₫ price must never drift through a USD round-trip.
        #expect(CurrencyConverter.shared.convert(1_234_567, from: .vnd, to: .vnd) == 1_234_567)
        #expect(Money.format(1_234_567, from: .vnd, to: .vnd) == "1.234.567₫")
    }

    @Test func inputSanitizeAndParse() {
        #expect(Money.sanitizeInput("12a3.4567", .usd) == "123.45")
        #expect(Money.sanitizeInput("80,5", .usd) == "80.5")
        #expect(Money.sanitizeInput("1.2.3", .usd) == "1.23")
        #expect(Money.sanitizeInput("2.500.000₫", .vnd) == "2500000")
        #expect(Money.amount(fromInput: "80.50", .usd) == 8050)
        #expect(Money.amount(fromInput: "80", .usd) == 8000)
        #expect(Money.amount(fromInput: "2500000", .vnd) == 2_500_000)
        #expect(Money.amount(fromInput: "", .usd, fallback: 7) == 7)
    }

    @Test func fieldText() {
        #expect(Money.fieldText(8000, from: .usd, to: .usd) == "80")
        #expect(Money.fieldText(8050, from: .usd, to: .usd) == "80.50")
        #expect(Money.fieldText(nil, from: .usd, to: .usd) == "")
        #expect(Money.fieldText(2_500_000, from: .vnd, to: .vnd) == "2500000")
    }

    @Test func growthAndCounts() {
        #expect(Money.growth(9.0) == "+9%")
        #expect(Money.growth(-3.5) == "-3.5%")
        #expect(Money.growth(0) == "0%")
        #expect(Money.growth(12.34) == "+12.3%")
        #expect(Money.count(28553) == "28,553")
        #expect(Money.oneDecimal(0.48) == "0.5")
        #expect(Money.oneDecimal(-3.0) == "-3.0")
    }
}

struct ValueAggregatorTests {
    private let now: Int64 = 1_800_000_000_000
    private let day: Int64 = 86_400_000

    private func pt(_ cents: Double, daysAgo: Int64 = 1, sale: Bool = false, native: Int64? = nil, ccy: AppCurrency? = .usd) -> ValuePoint {
        ValuePoint(value: cents, submittedAtMs: now - daysAgo * day, isSale: sale, nativeMinor: native ?? Int64(cents), nativeCurrency: ccy)
    }

    @Test func emptyIsNone() {
        #expect(ValueAggregator.aggregate([], retailUsdCents: 10_000, nowMs: now) == .none)
    }

    @Test func medianOddAndEven() {
        let odd = ValueAggregator.aggregate([pt(9_000), pt(10_000), pt(20_000)], retailUsdCents: 10_000, nowMs: now)
        #expect(odd.amountUsdCents == 10_000)
        #expect(odd.contributionCount == 3)
        #expect(odd.freshness == .fresh)
        let even = ValueAggregator.aggregate([pt(9_000), pt(10_000)], retailUsdCents: 10_000, nowMs: now)
        #expect(even.amountUsdCents == 9_500)
    }

    @Test func availableBandPaidVsSaleFloor() {
        // Retail $100: a PAID point passes at 60%, a SALE point needs 70%.
        let paid = ValueAggregator.aggregate([pt(6_500)], retailUsdCents: 10_000, tier: .available, nowMs: now)
        #expect(paid.amountUsdCents == 6_500)
        let sale = ValueAggregator.aggregate([pt(6_500, sale: true)], retailUsdCents: 10_000, tier: .available, nowMs: now)
        #expect(sale == .none)
        // Upper bound 5× for available, 20× for long-retired.
        #expect(ValueAggregator.aggregate([pt(60_000)], retailUsdCents: 10_000, tier: .available, nowMs: now) == .none)
        #expect(ValueAggregator.aggregate([pt(60_000)], retailUsdCents: 10_000, tier: .retiredOld, nowMs: now).amountUsdCents == 60_000)
    }

    @Test func noAnchorUsesAbsoluteBand() {
        let r = ValueAggregator.aggregate([pt(10), pt(1_500), pt(9_000_000)], retailUsdCents: nil, tier: .noAnchor, nowMs: now)
        #expect(r.amountUsdCents == 1_500)
        #expect(r.contributionCount == 1)
        // NO_ANCHOR ignores a retail figure even when one exists (promo/GWP).
        let promo = ValueAggregator.aggregate([pt(100)], retailUsdCents: 10_000, tier: .noAnchor, nowMs: now)
        #expect(promo.amountUsdCents == 100)
    }

    @Test func recentPointsWinOverOld() {
        let r = ValueAggregator.aggregate([pt(10_000, daysAgo: 10), pt(30_000, daysAgo: 900)], retailUsdCents: 10_000, nowMs: now)
        #expect(r.amountUsdCents == 10_000)
        #expect(r.contributionCount == 1)
        #expect(r.freshness == .fresh)
        #expect(r.newestAgeDays == 10)
        let stale = ValueAggregator.aggregate([pt(12_000, daysAgo: 800), pt(30_000, daysAgo: 900)], retailUsdCents: 10_000, nowMs: now)
        #expect(stale.freshness == .stale)
        #expect(stale.amountUsdCents == 21_000)
        #expect(stale.newestAgeDays == 800)
    }

    @Test func nativeMedianOnlyWhenUnanimous() {
        let vnd = ValueAggregator.aggregate(
            [pt(10_000, native: 2_600_000, ccy: .vnd), pt(12_000, native: 3_120_000, ccy: .vnd)],
            retailUsdCents: nil, tier: .noAnchor, nowMs: now
        )
        #expect(vnd.nativeCurrency == .vnd)
        #expect(vnd.nativeMinor == 2_860_000)
        #expect(vnd.displayMinor(.vnd) == 2_860_000) // exact, no USD round-trip
        let mixed = ValueAggregator.aggregate(
            [pt(10_000, native: 2_600_000, ccy: .vnd), pt(12_000, ccy: .usd)],
            retailUsdCents: nil, tier: .noAnchor, nowMs: now
        )
        #expect(mixed.nativeCurrency == nil)
        #expect(mixed.nativeMinor == nil)
    }

    @Test func tiers() {
        #expect(ValueAggregator.tier(for: .promo, retiredYear: 0, retiredMonth: 0) == .noAnchor)
        #expect(ValueAggregator.tier(for: .gwp, retiredYear: 2020, retiredMonth: 1) == .noAnchor)
        #expect(ValueAggregator.tier(for: .available, retiredYear: 0, retiredMonth: 0) == .available)
        #expect(ValueAggregator.tier(for: .retired, retiredYear: 0, retiredMonth: 0) == .retiredOld)
        let cal = Calendar.current
        let nowDate = Date(timeIntervalSince1970: Double(now) / 1000)
        let recent = cal.dateComponents([.year, .month], from: cal.date(byAdding: .month, value: -6, to: nowDate)!)
        #expect(ValueAggregator.tier(for: .retired, retiredYear: recent.year!, retiredMonth: recent.month!, nowMs: now) == .retiredRecent)
        let old = cal.dateComponents([.year, .month], from: cal.date(byAdding: .year, value: -3, to: nowDate)!)
        #expect(ValueAggregator.tier(for: .retired, retiredYear: old.year!, retiredMonth: old.month!, nowMs: now) == .retiredOld)
    }
}

struct TimestampTests {
    @Test func parsesPostgrestForms() {
        // PostgREST emits microseconds + "+00:00"; both that and "Z" must parse (else LWW reads epoch 0).
        let micro = ISO8601.millis("2026-09-05T12:34:56.789123+00:00")
        let z = ISO8601.millis("2026-09-05T12:34:56.789Z")
        let plain = ISO8601.millis("2026-09-05T12:34:56+00:00")
        #expect(micro == z)
        #expect(plain == z - 789)
        #expect(ISO8601.millis("garbage") == 0)
        #expect(ISO8601.millis(nil) == 0)
    }

    @Test func roundTripsMillis() {
        let ms: Int64 = 1_788_000_123_456
        let s = ISO8601.string(millis: ms)
        #expect(s.hasSuffix("Z"))
        #expect(ISO8601.millis(s) == ms)
    }

    @Test func localDay() {
        #expect(LocalDay("2026-03-01T00:00:00")?.month == 3)
        #expect(LocalDay("2026") == nil)
        #expect(LocalDay("2026-13-01") == nil)
        #expect(LocalDay("2025-12-31")! < LocalDay("2026-01-01")!)
        #expect(LocalDay("2026-01-05")!.iso == "2026-01-05")
    }
}

struct CatalogImagesTests {
    @Test func themeSlugMatchesAndroid() {
        #expect(CatalogImages.themeSlug("DC Comics Super Heroes") == "dc-comics-super-heroes")
        #expect(CatalogImages.themeSlug("Pokémon") == "pokemon")
        #expect(CatalogImages.themeSlug("Gabby's Dollhouse") == "gabbys-dollhouse")
        #expect(CatalogImages.themeSlug("Gabby’s Dollhouse") == "gabbys-dollhouse")
        #expect(CatalogImages.themeSlug("  Star Wars™ / Misc. ") == "star-wars-misc")
    }

    @Test func urlsLowercaseAndConvert() {
        #expect(CatalogImages.renderUrl("COMCON022", variant: 1) == "https://cdn.rebrickable.com/media/sets/comcon022-1.jpg")
        let thumb = CatalogImages.thumbUrl("75192", variant: 1)
        #expect(thumb == "https://cdn.rebrickable.com/media/thumbs/sets/75192-1.jpg/320x320p.jpg")
        #expect(CatalogImages.renderFromThumb(thumb) == "https://cdn.rebrickable.com/media/sets/75192-1.jpg")
        #expect(CatalogImages.thumbFromRender("https://cdn.rebrickable.com/media/sets/71050-7.jpg") ==
            "https://cdn.rebrickable.com/media/thumbs/sets/71050-7.jpg/320x320p.jpg")
        #expect(CatalogImages.renderFromThumb("https://example.com/x.png") == "https://example.com/x.png")
    }
}

struct NewSetsTests {
    private func set(_ n: String, _ y: Int, _ m: Int, _ status: Availability = .available, theme: String = "City") -> CatalogSet {
        CatalogSet(setNumber: n, name: n, theme: theme, releaseYear: y, releaseMonth: m, pieces: 0, minifigs: 0, retailPrice: nil, status: status)
    }

    @Test func selectsPendingAndTwoMonths() {
        let now = Calendar.current.date(from: DateComponents(year: 2026, month: 1, day: 15))!
        let picked = NewSets.select([
            set("a", 2026, 1), set("b", 2025, 12), set("c", 2025, 11), set("d", 2026, 0),
            set("e", 2027, 3, .pending), set("f", 2026, 1),
        ], now: now).map(\.setNumber)
        // Pending first, then newest release, then set number; Nov + year-only are out.
        #expect(picked == ["e", "a", "f", "b"])
    }
}

@MainActor
struct CSVTests {
    @Test func roundTripsAllThreeRecordTypes() throws {
        let copy = CollectionCopy(
            setId: 31337, figNum: nil, itemKind: "set", setNumber: "75192", name: "Millennium \"Falcon\", UCS",
            theme: "Star Wars", subtheme: "UCS", releaseYear: 2017, releaseMonth: 10, pieces: 7541, minifigs: 8,
            retailPrice: 84_999, status: "AVAILABLE", imageUrl: "https://x/y.jpg",
            quantity: 2, condition: "used", pricePaid: 150_000, currency: "USD",
            acquiredOn: "2026-01-02", notes: "line1\nline2, with comma", updatedAt: 1, dirty: false
        )
        let sale = Sale(
            setId: nil, figNum: "fig-000123", itemKind: "minifig", setNumber: "fig-000123", name: "Boba",
            theme: "Star Wars", imageUrl: nil, retailPrice: nil, quantity: 1, condition: "new",
            pricePaid: 500_000, salePrice: 900_000, currency: "VND", soldOn: "2026-02-03", notes: nil,
            updatedAt: 1, dirty: false
        )
        let wish = WishlistItem(
            setId: 9, figNum: nil, itemKind: "set", setNumber: "10300", name: "DeLorean", theme: "Icons",
            retailPrice: 19_999, status: "RETIRED", imageUrl: nil, updatedAt: 1, dirty: false
        )
        let csv = CollectionCSV.encode(copies: [copy], sales: [sale], wishlist: [wish])
        #expect(csv.hasPrefix("format_version,record_type,set_number,name,item_kind,fig_num,set_id,"))

        let parsed = CollectionCSV.parse(csv)
        #expect(CollectionCSV.version(of: parsed) == 2)
        #expect(parsed.rows.count == 3)

        let back = CollectionCSV.rows(from: parsed, setIdByNumber: [:], now: 42)
        #expect(back.copies.count == 1 && back.sales.count == 1 && back.wishlist.count == 1)
        let c = try #require(back.copies.first)
        #expect(c.name == "Millennium \"Falcon\", UCS")
        #expect(c.notes == "line1\nline2, with comma")
        #expect(c.setId == 31337 && c.quantity == 2 && c.condition == "used" && c.pricePaid == 150_000)
        #expect(c.dirty && c.updatedAt == 42 && c.id != copy.id) // fresh id, marked dirty
        let s = try #require(back.sales.first)
        #expect(s.figNum == "fig-000123" && s.setId == nil && s.currency == "VND" && s.salePrice == 900_000)
        #expect(back.wishlist.first?.status == "RETIRED")
    }

    @Test func cmfRoundTripsAsSetIdReference() throws {
        // A CMF is minifig-KIND but set_id-referenced; the round-trip must keep it that way and NOT
        // turn it into a fig_num row (which would carry both refs and fail the server one_ref XOR).
        let cmf = CollectionCopy(
            setId: 71050, figNum: nil, itemKind: "minifig", setNumber: "71050", name: "CMF Knight",
            theme: "Collectable Minifigures", subtheme: "Series 23", releaseYear: 2022, releaseMonth: 1,
            pieces: 7, minifigs: 1, retailPrice: 499, status: "AVAILABLE", imageUrl: nil,
            quantity: 1, condition: "new", pricePaid: 500_000, currency: "VND",
            acquiredOn: nil, notes: nil, updatedAt: 1, dirty: false
        )
        let parsed = CollectionCSV.parse(CollectionCSV.encode(copies: [cmf], sales: [], wishlist: []))
        let back = try #require(CollectionCSV.rows(from: parsed, setIdByNumber: [:], now: 7).copies.first)
        #expect(back.itemKind == "minifig" && back.setId == 71050 && back.figNum == nil && back.setNumber == "71050")
    }

    @Test func toleratesCRLFBomAndV1Files() {
        let v1 = "\u{FEFF}set_number,name,item_kind,quantity,price_paid\r\n10300,DeLorean,set,3,1000\r\n\r\n"
        let parsed = CollectionCSV.parse(v1)
        #expect(parsed.header.first == "set_number")
        #expect(CollectionCSV.version(of: parsed) == 1)
        let rows = CollectionCSV.rows(from: parsed, setIdByNumber: ["10300": 77], now: 1)
        #expect(rows.copies.count == 1) // no record_type → collection copy
        #expect(rows.copies.first?.setId == 77) // resolved from the catalog map
        #expect(rows.copies.first?.quantity == 3)
    }
}

/// The write funnel against an in-memory store: merge rules, sale proration, wishlist auto-removal.
@MainActor
struct CollectionServiceTests {
    private func makeService() throws -> (CollectionService, ModelContext) {
        let container = try UserDataStore.makeContainer(inMemory: true)
        let service = CollectionService(container: container, sync: SyncScheduler(container: container))
        return (service, container.mainContext)
    }

    private let falcon = CatalogSet(
        setNumber: "75192", name: "Falcon", theme: "Star Wars", releaseYear: 2017, releaseMonth: 10,
        pieces: 7541, minifigs: 8, retailPrice: 84_999, status: .available, setId: 1
    )

    @Test func identicalCopiesMergeDifferentOnesDoNot() throws {
        let (service, ctx) = try makeService()
        service.addCopy(of: falcon, .init(condition: .new, qty: 1, pricePaid: 80_000, currency: .usd, date: "2026-01-01"))
        service.addCopy(of: falcon, .init(condition: .new, qty: 2, pricePaid: 160_000, currency: .usd, date: "2026-01-01"))
        var rows = try CollectionCopy.fetchActive(in: ctx)
        #expect(rows.count == 1)
        #expect(rows[0].quantity == 3 && rows[0].pricePaid == 240_000 && rows[0].dirty)

        // Different per-unit price, and different currency → separate rows.
        service.addCopy(of: falcon, .init(condition: .new, qty: 1, pricePaid: 70_000, currency: .usd, date: "2026-01-01"))
        service.addCopy(of: falcon, .init(condition: .new, qty: 1, pricePaid: 80_000, currency: .vnd, date: "2026-01-01"))
        rows = try CollectionCopy.fetchActive(in: ctx)
        #expect(rows.count == 3)
    }

    @Test func owningRemovesFromWishlist() throws {
        let (service, ctx) = try makeService()
        service.addToWishlist(falcon)
        service.addToWishlist(falcon) // idempotent
        #expect(try WishlistItem.fetchActive(in: ctx).count == 1)
        service.addCopy(of: falcon, .init(pricePaid: 80_000))
        #expect(try WishlistItem.fetchActive(in: ctx).isEmpty)
        // Soft delete: the tombstone is kept (dirty) so the removal syncs.
        let all = try ctx.fetch(FetchDescriptor<WishlistItem>())
        #expect(all.count == 1 && all[0].tombstoned && all[0].dirty)
    }

    @Test func partialSaleProratesCostAndConservesPaid() throws {
        let (service, ctx) = try makeService()
        service.addCopy(of: falcon, .init(qty: 3, pricePaid: 240_000, currency: .usd))
        let id = try #require(try CollectionCopy.fetchActive(in: ctx).first?.id)
        service.sellCopy(id: id, quantity: 1, salePrice: 100_000, currency: .usd, soldOn: "2026-03-01")

        let copy = try #require(try CollectionCopy.fetchActive(in: ctx).first)
        let sale = try #require(try Sale.fetchActive(in: ctx).first)
        #expect(copy.quantity == 2 && copy.pricePaid == 160_000)
        #expect(sale.quantity == 1 && sale.pricePaid == 80_000 && sale.salePrice == 100_000)
        #expect(copy.pricePaid + sale.pricePaid == 240_000)

        // Selling the rest one-by-one at the same unit price merges into the same sales row…
        service.sellCopy(id: id, quantity: 1, salePrice: 100_000, currency: .usd, soldOn: "2026-03-01")
        #expect(try Sale.fetchActive(in: ctx).count == 1)
        #expect(try Sale.fetchActive(in: ctx).first?.quantity == 2)
        // …and selling the last unit tombstones the copy.
        service.sellCopy(id: id, quantity: 5, salePrice: 100_000, currency: .usd, soldOn: "2026-03-01")
        #expect(try CollectionCopy.fetchActive(in: ctx).isEmpty)
        #expect(try Sale.fetchActive(in: ctx).first?.quantity == 3)
    }

    @Test func minifigRowsAreKeyedByFigNum() throws {
        let (service, ctx) = try makeService()
        let fig = CatalogSet.fromMinifig(Minifig(figNum: "fig-000123", name: "Boba Fett", imageUrl: "https://i/f.jpg"))
        service.addCopy(of: fig, .init(pricePaid: 500_000, currency: .vnd))
        let row = try #require(try CollectionCopy.fetchActive(in: ctx).first)
        #expect(row.itemKind == "minifig" && row.figNum == "fig-000123" && row.setId == nil && row.setNumber == "fig-000123")
    }

    @Test func cmfRowsAreKeyedBySetIdNotFigNum() throws {
        // A Collectible Minifigure lives in the `sets` table (item_type=minifig) with a real set_id, so
        // adding one must store it by set_id — storing its set_number as a fig_num breaks the server FK.
        let (service, ctx) = try makeService()
        let cmf = CatalogSet(
            setNumber: "71050", name: "CMF Knight", itemType: .minifig, theme: "Collectable Minifigures",
            releaseYear: 2022, releaseMonth: 1, pieces: 7, minifigs: 1, retailPrice: 499, status: .available,
            setId: 71050
        )
        service.addCopy(of: cmf, .init(pricePaid: 500_000, currency: .vnd))
        let row = try #require(try CollectionCopy.fetchActive(in: ctx).first)
        #expect(row.itemKind == "minifig" && row.setId == 71050 && row.figNum == nil && row.setNumber == "71050")
    }

    @Test func cmfReconstructorsPreserveSetId() {
        // Re-adding from a sold or wishlisted CMF must keep set_id — else addCopy/addSale would see
        // itemType==.minifig && setId==nil and re-store the CMF by fig_num (the corruption). An in-set
        // fig (setId nil) must stay fig-referenced.
        let cmfSale = SoldItem(
            id: "s1", setNumber: "71050", name: "CMF Knight", itemType: .minifig, theme: "CMF",
            releaseYear: 2022, releaseMonth: 1, retailPrice: 499, pricePaid: 0, saleValue: 100,
            setId: 71050, figNum: nil)
        let cmfWish = WishlistEntry(
            rowId: "w1", setNumber: "71050", name: "CMF Knight", itemType: .minifig, theme: "CMF",
            releaseYear: 2022, releaseMonth: 1, pieces: 7, minifigs: 1, retailPrice: 499,
            setId: 71050, figNum: nil)
        let figSale = SoldItem(
            id: "s2", setNumber: "fig-000123", name: "Boba", itemType: .minifig, theme: "SW",
            releaseYear: 0, releaseMonth: 0, retailPrice: 0, pricePaid: 0, saleValue: 1,
            setId: nil, figNum: "fig-000123")
        #expect(CatalogSet(cmfSale).setId == 71050 && CatalogSet(cmfSale).itemType == .minifig)
        #expect(CatalogSet(cmfWish).setId == 71050 && CatalogSet(cmfWish).itemType == .minifig)
        #expect(CatalogSet(figSale).setId == nil) // in-set fig stays fig-referenced
    }

    @Test func statsSumInDisplayCurrency() throws {
        let (service, ctx) = try makeService()
        service.addCopy(of: falcon, .init(qty: 2, pricePaid: 100_000, currency: .usd))
        let items = DisplayBuilder.collectionItems(try CollectionCopy.fetchActive(in: ctx))
        let summary = CollectionStats.summary(of: items, display: .usd)
        #expect(summary.setCount == 2 && summary.minifigCount == 16 && summary.pieceCount == 15_082)
        #expect(summary.paid == 100_000)
        #expect(summary.collectionValue == 169_998) // available set → worth = retail × qty
        #expect(items.first?.growthPercent != nil)
    }
}
