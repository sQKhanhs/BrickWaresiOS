import Foundation
import SwiftData
import Testing
@testable import BrickWares

// Android pre-release batch, P1: money prefill (c626259), Total Sold (9d30ca2), the sign-up fake success
// (8ea4bd0) and image failures that aren't final (31dcc5d).

struct RetailPrefillTests {
    @Test func prefillIsRetailTimesQuantity() {
        // Stored amounts are the TOTAL for the quantity: 3 units at $49.99 retail prefill $149.97.
        #expect(Money.retailFieldText(4999, units: 1, to: .usd) == "49.99")
        #expect(Money.retailFieldText(4999, units: 3, to: .usd) == "149.97")
        #expect(Money.retailFieldText(5000, units: 2, to: .usd) == "100") // trailing ".00" trimmed
        #expect(Money.retailFieldText(5000, units: 0, to: .usd) == "50")  // never below one unit
    }

    @Test func noPrefillWithoutRetailOrWhenItWouldNotFitTheField() {
        #expect(Money.retailFieldText(nil, units: 3, to: .usd) == nil)
        #expect(Money.retailFieldText(0, units: 3, to: .usd) == nil)
        // 11 whole digits: the field's sanitizer keeps 10, which would silently become a different amount.
        #expect(Money.retailFieldText(99_999_999_900, units: 100, to: .usd) == nil)
    }
}

@MainActor
struct SalesSummaryTests {
    @Test func totalSoldCountsUnitsNotRows() throws {
        let container = try UserDataStore.makeContainer(inMemory: true)
        let service = CollectionService(container: container, sync: SyncScheduler(container: container))
        let falcon = CatalogSet(
            setNumber: "75192", name: "Falcon", theme: "Star Wars", releaseYear: 2017, releaseMonth: 10,
            pieces: 7541, minifigs: 8, retailPrice: 84_999, status: .available, setId: 1
        )
        // One sale of 3 units, and a single-unit sale on another day: 2 rows, 4 units.
        service.addSale(of: falcon, qty: 3, condition: .new, paid: 240_000, salePrice: 270_000, currency: .usd, soldOn: "2026-09-01", note: nil)
        service.addSale(of: falcon, qty: 1, condition: .new, paid: 80_000, salePrice: 95_000, currency: .usd, soldOn: "2026-09-15", note: nil)
        let sold = DisplayBuilder.sold(try Sale.fetchActive(in: container.mainContext))
        #expect(sold.count == 2)
        let summary = CollectionStats.salesSummary(of: sold, display: .usd)
        #expect(summary.totalSold == 4)
        #expect(summary.totalSaleValue == 365_000 && summary.totalProfit == 45_000)
    }
}

struct SignUpOutcomeTests {
    @Test func emptyIdentitiesMeansTheAddressIsAlreadyRegistered() {
        #expect(AuthService.signUpOutcome(hasSession: true, identityCount: 1) == .success)           // auto-confirm
        #expect(AuthService.signUpOutcome(hasSession: false, identityCount: 1) == .emailConfirmationRequired)
        #expect(AuthService.signUpOutcome(hasSession: false, identityCount: nil) == .emailConfirmationRequired)
        // GoTrue's fake success for a confirmed address: no email is sent, so the code screen is a dead end.
        #expect(AuthService.signUpOutcome(hasSession: false, identityCount: 0) == .emailAlreadyRegistered)
    }
}

struct ImageFailureTests {
    @Test func onlyADefinitiveAnswerIsRememberedAsMissing() {
        for status in [404, 403, 410, 400, 401] { #expect(ImageLoader.isDefinitivelyMissing(status: status), "\(status)") }
        // Rate-limited, timed out or a server error: try again later, never "no image" for the session.
        for status in [408, 429, 500, 502, 503] { #expect(!ImageLoader.isDefinitivelyMissing(status: status), "\(status)") }
    }
}
