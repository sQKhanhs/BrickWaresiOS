import Foundation
import SwiftData
import Testing
@testable import BrickWares

// The combined P2 pass: note markup (80fd67a), book covers + duplicate variants (d755af9), and the
// zero-quantity sell guard (e74c4fb / a0c373d).

struct NoteMarkupTests {
    typealias Run = NoteMarkup.Run

    @Test func plainNotesPassThroughUntouched() {
        let note = "Barnes & Noble exclusive, 2 < 3."
        #expect(!NoteMarkup.hasMarkup(note))
        #expect(String(NoteMarkup.attributed(note).characters) == note)
    }

    // The three shapes that occur on prod (the only tags Brickset uses are <a> and <br>).

    @Test func breakThenLinkBecomesANewLineAndATappableLink() {
        let note = #"This set was due for release in November 2012 but was not. <br/> <a href="http://www.1000steine.de/x/40046-1.pdf">View instructions</a>"#
        #expect(NoteMarkup.runs(note) == [
            Run(text: "This set was due for release in November 2012 but was not.\n", link: nil),
            Run(text: "View instructions", link: URL(string: "http://www.1000steine.de/x/40046-1.pdf")),
        ])
    }

    @Test func bareOpeningTagIsRepairedAsAClose() {
        // "…HoMa<a>)" is Brickset's typo for "</a>": without the repair the ")" would join the link.
        let note = "Author: Hoger Matthes (<a href='https://brickset.com/profile/HoMa'>HoMa<a>)"
        #expect(NoteMarkup.runs(note) == [
            Run(text: "Author: Hoger Matthes (", link: nil),
            Run(text: "HoMa", link: URL(string: "https://brickset.com/profile/HoMa")),
            Run(text: ")", link: nil),
        ])
    }

    @Test func leadingAndTrailingBreaksAreDroppedAndOwnLineBreaksKept() {
        #expect(NoteMarkup.runs("<br>First line.\nSecond line.<br/>") == [Run(text: "First line.\nSecond line.", link: nil)])
    }

    @Test func onlyWebLinksBecomeLinks() {
        // A note is untrusted catalog text: a custom scheme keeps its text but never becomes tappable.
        #expect(NoteMarkup.runs("<a href='javascript:alert(1)'>x</a> <a href='tel:123'>y</a>") == [Run(text: "x y", link: nil)])
        let attributed = NoteMarkup.attributed("See <a href=\"https://example.com/a?b=1&c=2\">this</a>.")
        #expect(String(attributed.characters) == "See this.")
        #expect(attributed.runs.compactMap { $0.link } == [URL(string: "https://example.com/a?b=1&c=2")!])
    }
}

struct CatalogCleanupTests {
    @Test func bookCoversUseTheBareIsbn() {
        // Both CDNs host a book under the bare ISBN; the raw "ISBN…" number 404s.
        #expect(CatalogImages.imageSlug("ISBN9780241788080") == "9780241788080")
        #expect(CatalogImages.renderUrl("ISBN9780241788080") == "https://cdn.rebrickable.com/media/sets/9780241788080-1.jpg")
        #expect(CatalogImages.thumbUrl("isbn9780241788080", variant: 2).contains("/9780241788080-2.jpg/"))
        // Ordinary numbers are only lowercased.
        #expect(CatalogImages.imageSlug("COMCON022") == "comcon022")
        #expect(CatalogImages.renderUrl("10196") == "https://cdn.rebrickable.com/media/sets/10196-1.jpg")
    }

    private func set(_ number: String, _ name: String, variant: Int, pieces: Int = 10) -> CatalogSet {
        CatalogSet(setNumber: number, name: name, theme: "T", releaseYear: 2024, releaseMonth: 1, pieces: pieces,
                   minifigs: 1, retailPrice: nil, status: .available, numberVariant: variant, setId: Int64(variant))
    }

    @Test func contentIdenticalVariantsCollapseButRealVariantsStay() {
        let listed = CatalogRepository.listable([
            set("212504", "Superman", variant: 2),   // a Brickset duplicate of variant 1
            set("212504", "Superman", variant: 1),
            set("71050", "Miles Morales", variant: 1), // a real CMF series: same number, different figures
            set("71050", "Spider-Punk", variant: 2),
            set("71050", "Spider-Punk", variant: 2),   // the same row twice
        ])
        #expect(listed.map(\.id) == ["212504-1", "71050-1", "71050-2"])
    }
}

@MainActor
struct ZeroQuantitySellTests {
    @Test func anEmptyCopyIsRemovedNotSold() throws {
        let container = try UserDataStore.makeContainer(inMemory: true)
        let service = CollectionService(container: container, sync: SyncScheduler(container: container))
        let ctx = container.mainContext
        // A 0-quantity copy can arrive by sync (the server's CHECK allows 0).
        let empty = CollectionCopy(
            setId: 1, figNum: nil, itemKind: "set", setNumber: "75192", name: "Falcon", theme: "Star Wars",
            subtheme: "General", releaseYear: 2017, releaseMonth: 10, pieces: 7541, minifigs: 8, retailPrice: 84_999,
            status: Availability.available.rawValue, imageUrl: nil, quantity: 0, condition: "new", pricePaid: 0,
            currency: "USD", acquiredOn: nil, notes: nil, updatedAt: 1, dirty: false
        )
        ctx.insert(empty)
        service.sellCopy(id: empty.id, quantity: 1, salePrice: 90_000, currency: .usd, soldOn: nil)
        #expect(try Sale.fetchActive(in: ctx).isEmpty)            // no phantom 1-unit sale at zero cost
        #expect(try CollectionCopy.fetchActive(in: ctx).isEmpty)  // the empty row is tombstoned…
        #expect(empty.tombstoned && empty.dirty)                  // …and the removal syncs
    }
}
