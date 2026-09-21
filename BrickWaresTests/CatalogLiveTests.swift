import Foundation
import Testing
@testable import BrickWares

/// Read-only integration checks against the configured Supabase project. Skipped when the bundle has
/// no Secrets.plist (CI / fresh clone).
@Suite(.enabled(if: AppConfig.isConfigured), .serialized)
struct CatalogLiveTests {
    let catalog = CatalogRepository.shared

    @Test func browseCountsLoadConcurrentlyAndArePagedPastTheRowCap() async throws {
        async let themes = catalog.themeCounts()
        async let subs = catalog.subthemeCounts()
        let (t, s) = try await (themes, subs)
        #expect(t.count > 100)
        // PostgREST caps a page at 1000 rows; the view has ~1.7k. Getting more proves paging works.
        #expect(s.count > 1000)
        #expect(s.contains { $0.theme == "Star Wars" })
    }

    @Test func bigThemeIsNotTruncated() async throws {
        let sets = try await catalog.setsInTheme("Star Wars")
        #expect(sets.count > 1000)
        #expect(Set(sets.map(\.id)).count == sets.count)
    }

    @Test func searchHandlesReservedCharacters() async throws {
        #expect(try await catalog.searchSets("75192").contains { $0.setNumber == "75192" })
        // Commas / parens / percent must not break the or=(…) filter.
        _ = try await catalog.searchSets("x-wing, (red) 100%")
        _ = try await catalog.searchMinifigs("o'brien \"quoted\"")
    }

    @Test func setDetailDerivations() async throws {
        let falcon = try #require(try await catalog.fetchSet("75192-1"))
        #expect(falcon.retailPrice == 84_999) // US price exact, × 100
        #expect(falcon.releaseYear == 2017 && falcon.releaseMonth == 10)
        #expect(falcon.setId != nil)
        let figs = try await catalog.fetchMinifigs(forSet: try #require(falcon.setId))
        #expect(figs.count >= 8)
        let appears = try await catalog.fetchSets(forMinifig: try #require(figs.first?.figNum))
        #expect(appears.contains { $0.setNumber == "75192" })
    }

    @Test func minifigThemeBrowse() async throws {
        let figs = try await catalog.minifigsInTheme("Architecture")
        _ = figs // may be empty; must not throw (exercises the !inner embedded filter)
        #expect(try await catalog.minifigThemeCounts().count > 50)
    }
}
