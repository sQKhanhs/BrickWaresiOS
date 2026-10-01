import Foundation
import Testing
@testable import BrickWares

// Follow-ups from the 2026-10-01 Android doc review: the add sheet's prefill staying under the next item,
// and the retirement-alert baseline moving when nobody could be told (signed out) or not being reset
// when alerts are switched on.

struct PrefillFollowsTheItemTests {
    @Test func anUntouchedPrefillFollowsTheNewItem() {
        #expect(Money.prefilled("", edited: false, retail: "49.99") == "49.99")
        #expect(Money.prefilled("49.99", edited: false, retail: "129.99") == "129.99")
    }

    @Test func anUntouchedPrefillIsEmptiedWhenTheNewItemHasNoRetail() {
        // Pick a $49.99 set, clear it, pick one with no retail price: the field must not keep 49.99.
        #expect(Money.prefilled("49.99", edited: false, retail: nil) == "")
        #expect(Money.prefilled("", edited: false, retail: nil) == "")
    }

    @Test func aTypedAmountIsKept() {
        #expect(Money.prefilled("40", edited: true, retail: "129.99") == "40")
        #expect(Money.prefilled("40", edited: true, retail: nil) == "40")
        // Typed, then deleted again: an empty field takes the estimate.
        #expect(Money.prefilled("", edited: true, retail: "129.99") == "129.99")
    }
}

/// These read and write the stored baseline (UserDefaults), so they run one at a time and put it back.
@MainActor
@Suite(.serialized)
struct RetirementBaselineTests {
    private func entry(_ setId: Int64, _ name: String, _ status: Availability) -> WishlistEntry {
        WishlistEntry(
            rowId: "w\(setId)", setNumber: "\(setId)", name: name, itemType: .set, theme: "City",
            releaseYear: 2024, releaseMonth: 1, pieces: 100, minifigs: 1, retailPrice: 999,
            status: status, setId: setId, figNum: nil)
    }

    /// Runs `body` from a known stored baseline, then restores whatever was there.
    private func withBaseline(wishlist: Set<String>, retired: Set<String>, _ body: () -> Void) {
        let settings = AppSettings.shared
        let saved = (settings.lastWishlist, settings.lastRetired)
        defer { (settings.lastWishlist, settings.lastRetired) = saved }
        settings.lastWishlist = wishlist
        settings.lastRetired = retired
        body()
    }

    @Test func aRetirementSinceTheLastCheckAlertsOnce() {
        withBaseline(wishlist: ["s1"], retired: []) {
            #expect(RetirementAlerts.evaluate([entry(1, "Police Station", .retired)]) == ["Police Station"])
            #expect(RetirementAlerts.evaluate([entry(1, "Police Station", .retired)]).isEmpty)
        }
    }

    @Test func noCheckWhileSignedOutOrSwitchedOff() {
        // Signed out, the baseline must not move — the retirement still alerts once the account is back.
        #expect(!RetirementAlerts.shouldCheck(enabled: true, auth: .signedOut))
        #expect(!RetirementAlerts.shouldCheck(enabled: false, auth: .loading))
        #expect(RetirementAlerts.shouldCheck(enabled: true, auth: .loading))
        withBaseline(wishlist: ["s1"], retired: []) {
            // (no evaluation happened while signed out) → back in, the pending retirement is reported.
            #expect(RetirementAlerts.evaluate([entry(1, "Police Station", .retired)]) == ["Police Station"])
        }
    }

    @Test func switchingAlertsOnReportsOnlyFutureRetirements() {
        // Baseline frozen while alerts were off; set 1 retired in the meantime.
        withBaseline(wishlist: ["s1", "s2"], retired: []) {
            RetirementAlerts.resetBaseline()
            let offPeriod = [entry(1, "Police Station", .retired), entry(2, "Fire Truck", .available)]
            #expect(RetirementAlerts.evaluate(offPeriod).isEmpty) // silent re-baseline
            let later = [entry(1, "Police Station", .retired), entry(2, "Fire Truck", .retired)]
            #expect(RetirementAlerts.evaluate(later) == ["Fire Truck"])
        }
    }
}
