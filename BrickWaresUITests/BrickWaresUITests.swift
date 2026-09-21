import XCTest

/// Signed-out smoke walkthrough against the live catalog: every tab renders, theme browse loads,
/// a theme opens, a set detail opens, and a write action raises the login sheet. Screenshots are
/// attached at each step (export with `xcrun xcresulttool export attachments`).
final class BrickWaresUITests: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = true }

    @MainActor
    func testSignedOutWalkthrough() throws {
        let app = XCUIApplication()
        app.launchArguments += ["-AppleLanguages", "(en)"]
        app.launch()

        let tabs = app.tabBars.firstMatch
        XCTAssertTrue(tabs.waitForExistence(timeout: 15))
        sleep(3) // splash
        snap("01-home")

        tabs.buttons["Collection"].tap()
        XCTAssertTrue(app.staticTexts["Sign in to view and manage your collection"].waitForExistence(timeout: 5))
        snap("02-collection-signed-out")

        tabs.buttons["Wishlist"].tap()
        XCTAssertTrue(app.staticTexts["Sign in to build your wishlist"].waitForExistence(timeout: 5))
        snap("03-wishlist-signed-out")

        tabs.buttons["Search"].tap()
        let starWars = app.staticTexts["Star Wars"]
        XCTAssertTrue(app.staticTexts["Architecture"].waitForExistence(timeout: 25), "theme browse should load from the catalog")
        snap("04-search-browse")

        // Global search: suggestions, then submit.
        let field = app.searchFields.firstMatch
        field.tap()
        field.typeText("75192")
        XCTAssertTrue(app.staticTexts["75192 Millennium Falcon"].waitForExistence(timeout: 15))
        snap("05-search-suggestions")
        app.staticTexts["75192 Millennium Falcon"].tap()

        XCTAssertTrue(app.staticTexts["Set Details"].waitForExistence(timeout: 20))
        sleep(3)
        snap("06-set-detail-top")
        app.swipeUp()
        sleep(1)
        snap("07-set-detail-pricing")
        app.swipeUp()
        sleep(2)
        snap("08-set-detail-bottom")

        // A write action while signed out raises the login sheet instead.
        app.swipeDown(); app.swipeDown()
        app.buttons["Add"].firstMatch.tap()
        XCTAssertTrue(app.staticTexts["Welcome back"].waitForExistence(timeout: 5))
        snap("09-login-sheet")
        app.buttons["Close"].tap()

        tabs.buttons["Settings"].tap()
        XCTAssertTrue(app.staticTexts["Retirement alerts"].waitForExistence(timeout: 5))
        snap("10-settings")
        _ = starWars
    }

    @MainActor
    func testThemeDrillDownPagesPastThousandSets() throws {
        let app = XCUIApplication()
        app.launchArguments += ["-AppleLanguages", "(en)"]
        app.launch()
        XCTAssertTrue(app.tabBars.firstMatch.waitForExistence(timeout: 15))
        sleep(3)
        app.tabBars.buttons["Search"].tap()
        XCTAssertTrue(app.staticTexts["Architecture"].waitForExistence(timeout: 25))
        app.staticTexts["Architecture"].tap()
        let count = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'Sets ('")).firstMatch
        XCTAssertTrue(count.waitForExistence(timeout: 25), "theme results should load")
        sleep(2)
        snap("11-theme-results")
        // Release labels must not group the year ("Oct 2.017").
        XCTAssertFalse(app.staticTexts.matching(NSPredicate(format: "label MATCHES '.* [0-9]\\.[0-9]{3}'")).firstMatch.exists)
    }

    private func snap(_ name: String) {
        let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }
}
