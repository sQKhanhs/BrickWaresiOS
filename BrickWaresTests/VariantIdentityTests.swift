import Foundation
import SwiftData
import Testing
@testable import BrickWares

// Shared-number variants (a CMF series like 71050 shares ONE set_number across its figures, each with its
// own set_id) must behave as distinct items everywhere — Android 6f9f009 / 5e9bda7 / 84f50b5 / 7912d6a.

struct ItemKeyTests {
    @Test func keysPreferSetIdAndNeverCollideWithANumber() {
        #expect(ItemKey.of(setId: 51463, setNumber: "71050") == "s51463")
        #expect(ItemKey.of(setId: nil, figNum: "fig-000123", setNumber: "fig-000123") == "nfig-000123")
        #expect(ItemKey.of(setId: nil, setNumber: "71050") == "n71050")         // legacy row
        #expect(ItemKey.lookup(setId: 51463, setNumber: "71050") == ["s51463", "n71050"])
        #expect(ItemKey.lookup(setId: nil, setNumber: "fig-1") == ["nfig-1"])
    }

    @Test func ownedRowsRouteToTheirExactVariant() {
        #expect(CatalogKey.forRow(setId: 51463, setNumber: "71050") == "sid:51463")
        #expect(CatalogKey.forRow(setId: nil, setNumber: "71050") == "71050")
        #expect(CatalogKey.setId("sid:51463") == 51463)
        #expect(CatalogKey.setId("71050-2") == nil)
        #expect(CatalogKey.setId("sid:") == nil)
    }
}

@MainActor
struct VariantIdentityTests {
    private func makeService() throws -> (CollectionService, ModelContext) {
        let container = try UserDataStore.makeContainer(inMemory: true)
        return (CollectionService(container: container, sync: SyncScheduler(container: container)), container.mainContext)
    }

    /// Two figures of one CMF series: same number, different set_id.
    private func figure(_ variant: Int, id: Int64) -> CatalogSet {
        CatalogSet(
            setNumber: "71050", name: "Figure \(variant)", itemType: .minifig, theme: "Collectable Minifigures",
            releaseYear: 2023, releaseMonth: 6, pieces: 6, minifigs: 1, retailPrice: 499, status: .available,
            numberVariant: variant, setId: id
        )
    }

    private func legacyCopy(pricePaid: Int64 = 500) -> CollectionCopy {
        CollectionCopy(
            setId: nil, figNum: nil, itemKind: "minifig", setNumber: "71050", name: "Unknown figure",
            theme: "Collectable Minifigures", subtheme: "General", releaseYear: 2023, releaseMonth: 6,
            pieces: 6, minifigs: 1, retailPrice: 499, status: Availability.available.rawValue, imageUrl: nil,
            quantity: 1, condition: "new", pricePaid: pricePaid, currency: "USD", acquiredOn: nil, notes: nil,
            updatedAt: 1, dirty: true
        )
    }

    @Test func identicalCopiesOfDifferentVariantsNeverMerge() throws {
        let (service, ctx) = try makeService()
        service.addCopy(of: figure(2, id: 1002), .init(pricePaid: 500))
        service.addCopy(of: figure(4, id: 1004), .init(pricePaid: 500)) // identical copy, other figure
        let rows = try CollectionCopy.fetchActive(in: ctx)
        #expect(Set(rows.compactMap(\.setId)) == [1002, 1004])
        let items = DisplayBuilder.collectionItems(rows)
        #expect(items.count == 2)                          // one card per figure
        #expect(Set(items.map(\.id)).count == 2)           // distinct list identities
    }

    @Test func swipeDeletingOneVariantKeepsItsSiblings() throws {
        let (service, ctx) = try makeService()
        service.addCopy(of: figure(2, id: 1002), .init(pricePaid: 500))
        service.addCopy(of: figure(4, id: 1004), .init(pricePaid: 700))
        service.removeItem(setNumber: "71050", setId: 1002)
        #expect(try CollectionCopy.fetchActive(in: ctx).compactMap(\.setId) == [1004])
    }

    @Test func wishlistIsPerVariant() throws {
        let (service, ctx) = try makeService()
        service.addToWishlist(figure(2, id: 1002))
        service.addToWishlist(figure(4, id: 1004))        // not blocked by its sibling
        service.addToWishlist(figure(4, id: 1004))        // but idempotent for itself
        #expect(Set(try WishlistItem.fetchActive(in: ctx).compactMap(\.setId)) == [1002, 1004])

        service.addCopy(of: figure(2, id: 1002), .init(pricePaid: 500)) // owning 2 clears only 2
        #expect(try WishlistItem.fetchActive(in: ctx).compactMap(\.setId) == [1004])

        service.toggleWishlist(figure(4, id: 1004), isWishlisted: true)
        #expect(try WishlistItem.fetchActive(in: ctx).isEmpty)
    }

    @Test func numberMatchesReachOnlyLegacySetIdLessRows() throws {
        let (service, ctx) = try makeService()
        ctx.insert(legacyCopy())
        // An identical copy of a cataloged variant must not merge into the unattributed legacy row…
        service.addCopy(of: figure(2, id: 1002), .init(pricePaid: 500))
        #expect(try CollectionCopy.fetchActive(in: ctx).count == 2)
        // …and deleting the legacy card must not take the cataloged variant with it.
        service.removeItem(setNumber: "71050", setId: nil)
        #expect(try CollectionCopy.fetchActive(in: ctx).compactMap(\.setId) == [1002])
    }

    @Test func sellingMergesOnlyIntoTheSameVariantsSales() throws {
        let (service, ctx) = try makeService()
        service.addCopy(of: figure(2, id: 1002), .init(pricePaid: 500))
        service.addCopy(of: figure(4, id: 1004), .init(pricePaid: 500))
        for row in try CollectionCopy.fetchActive(in: ctx) {
            service.sellCopy(id: row.id, quantity: 1, salePrice: 900, currency: .usd, soldOn: "2026-09-29")
        }
        #expect(Set(try Sale.fetchActive(in: ctx).compactMap(\.setId)) == [1002, 1004]) // two sales, not one
    }

    @Test func ownershipMarksTheExactVariantPlusLegacyNumber() {
        let index = OwnershipIndex()
        index.update(owned: ["s1002"], wishlisted: ["s1004"], sold: [])
        #expect(index.isOwned(figure(2, id: 1002)))
        #expect(!index.isOwned(figure(4, id: 1004)))       // a sibling isn't owned
        #expect(index.isWishlisted(figure(4, id: 1004)))
        #expect(!index.isWishlisted(figure(2, id: 1002)))
        index.update(owned: ["n71050"], wishlisted: [], sold: [])
        #expect(index.isOwned(figure(7, id: 1007)))         // a legacy row still marks its number owned
    }
}

struct CSVVariantTests {
    private func variant(_ v: Int, id: Int64) -> CatalogSet {
        CatalogSet(setNumber: "71050", name: "v\(v)", theme: "CMF", releaseYear: 2023, releaseMonth: 6,
                   pieces: 0, minifigs: 1, retailPrice: nil, status: .available, numberVariant: v, setId: id)
    }

    @Test func blankSetIdResolvesExactOrSoleVariantAndNeverPinsTheLowest() {
        let many = [variant(1, id: 1001), variant(2, id: 1002), variant(4, id: 1004)]
        #expect(CollectionCSV.resolveSetId(variant: 4, among: many) == 1004)  // exact number_variant
        #expect(CollectionCSV.resolveSetId(variant: nil, among: many) == nil) // ambiguous → stays legacy
        #expect(CollectionCSV.resolveSetId(variant: 9, among: many) == nil)   // unknown variant → legacy
        #expect(CollectionCSV.resolveSetId(variant: nil, among: [variant(1, id: 77)]) == 77) // sole variant
        #expect(CollectionCSV.resolveSetId(variant: nil, among: []) == nil)
    }

    @MainActor
    @Test func exportCarriesNumberVariantFromSetIdOnly() throws {
        // A shared-number SET (SDCC-style). A minifig-kind row with a blank set_id is read as a fig ref by
        // design, so variant resolution is exercised on a set row.
        let row = CollectionCopy(
            setId: 1004, figNum: nil, itemKind: "set", setNumber: "71050", name: "v4", theme: "CMF",
            subtheme: "General", releaseYear: 2023, releaseMonth: 6, pieces: 6, minifigs: 1, retailPrice: nil,
            status: "available", imageUrl: nil, quantity: 1, condition: "new", pricePaid: 500, currency: "USD",
            acquiredOn: nil, notes: nil, updatedAt: 1, dirty: false
        )
        let parsed = CollectionCSV.parse(CollectionCSV.encode(copies: [row], sales: [], wishlist: []) { $0 == 1004 ? 4 : nil })
        let columns = parsed.header
        // Same position as Android: right after set_id, so files stay identical across platforms.
        let at = try #require(columns.firstIndex(of: "set_id"))
        #expect(columns[at + 1] == "number_variant")
        #expect(parsed.rows.first?.value("number_variant") == "4")
        // A re-import of that row with its set_id blanked resolves back to the SAME variant.
        var blanked = parsed
        blanked.rows[0]["set_id"] = ""
        let back = CollectionCSV.rows(from: blanked, now: 1) { _, v in
            CollectionCSV.resolveSetId(variant: v, among: [variant(1, id: 1001), variant(4, id: 1004)])
        }
        #expect(back.copies.first?.setId == 1004)
    }
}
