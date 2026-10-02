import Foundation
import Observation

enum SearchMode: String, CaseIterable, Identifiable {
    case sets, minifigs
    var id: String { rawValue }
}

enum ThemeSort: String, CaseIterable, Identifiable {
    case alphabetical, count, favorite
    var id: String { rawValue }

    var label: String {
        switch self {
        case .alphabetical: L("sort_alphabetical")
        case .count: L("sort_amount")
        case .favorite: L("sort_favorites")
        }
    }
}

enum ThemeViewMode { case detail, list }

struct ThemeGroup: Identifiable, Hashable {
    struct Subtheme: Hashable {
        var name: String
        var count: Int
    }

    var theme: String
    var count: Int
    var subthemes: [Subtheme]
    var id: String { theme }
}

/// Search tab state. The display mode is derived purely from query state:
/// browse (blank, nothing submitted) → live suggestions (typing) → results (submitted).
@MainActor
@Observable
final class SearchModel {
    static let maxResults = 20
    static let suggestionLimit = 6
    static let searchLimit = 100

    var mode: SearchMode = .sets { didSet { if mode != oldValue { modeChanged() } } }
    var query = "" { didSet { if query != oldValue { queryChanged() } } }
    private(set) var submittedQuery: String?

    var themeSort: ThemeSort = .alphabetical { didSet { freezeOrder() } }
    var viewMode: ThemeViewMode = .detail {
        didSet {
            // The compact list shows no counts, so "Amount of sets" isn't offered there.
            if viewMode == .list, themeSort == .count { themeSort = .alphabetical }
            themePage = 1
        }
    }
    /// The page of theme cards showing in the one-per-row view (ten a page, like Android; the compact
    /// grid shows every theme). Back to 1 whenever the order is rebuilt.
    private(set) var themePage = 1

    private(set) var setThemes: [ThemeGroup] = []
    private(set) var minifigThemes: [ThemeGroup] = []
    /// One phase PER mode. A single shared phase left the already-loaded Sets list on the error page after
    /// a failed minifig load, and flashed the other mode's "empty" state when switching mid-load.
    private var browsePhases: [SearchMode: LoadPhase] = [:]
    var browsePhase: LoadPhase { browsePhases[mode] ?? .loading }
    /// Display order, **frozen** at browse entry / sort / mode change — favoriting a theme must not
    /// reorder the list under the user's finger.
    private(set) var orderedThemeNames: [String] = []

    private(set) var setSuggestions: [CatalogSet] = []
    private(set) var minifigSuggestions: [Minifig] = []
    /// The suggestion lookup for the CURRENT query: `.pending` from the first keystroke (through the
    /// debounce and the round trip), `.failed` when both fetches errored. Without it an empty list read as
    /// "No matches" the whole time the user was typing, and a failed fetch said the same (Android ee0ee66).
    enum SuggestState { case idle, pending, failed }
    private(set) var suggestState: SuggestState = .idle
    private(set) var setResults: [CatalogSet] = []
    private(set) var minifigResults: [Minifig] = []
    private(set) var resultsPhase: LoadPhase = .loaded
    /// Bumped on every reset-to-home so the screen scrolls the browse list back to the top.
    private(set) var homeScrollTick = 0

    @ObservationIgnored private var searchTask: Task<Void, Never>?
    private let settings = AppSettings.shared
    private let catalog = CatalogRepository.shared

    var showBrowse: Bool { query.trimmingCharacters(in: .whitespaces).isEmpty && submittedQuery == nil }
    var showResults: Bool { submittedQuery != nil }
    var showSuggestions: Bool { !showBrowse && !showResults }
    /// A submitted search returning too many sets shows refine-your-search tips instead of a long list.
    var tooMany: Bool { setResults.count > Self.maxResults }

    var themes: [ThemeGroup] { mode == .sets ? setThemes : minifigThemes }
    var favorites: Set<String> { mode == .sets ? settings.favoriteSetThemes : settings.favoriteMinifigThemes }

    var orderedThemes: [ThemeGroup] {
        let byName = Dictionary(themes.map { ($0.theme, $0) }, uniquingKeysWith: { a, _ in a })
        let ordered = orderedThemeNames.compactMap { byName[$0] }
        // FAVORITE is a live filter (un-starring removes the card); the other sorts only pin.
        return themeSort == .favorite ? ordered.filter { favorites.contains($0.theme) } : ordered
    }

    // MARK: Browse

    func loadBrowse(force: Bool = false) async {
        let loading = mode // the mode this load is FOR — the user may switch while it runs
        guard force || (loading == .sets ? setThemes : minifigThemes).isEmpty else { return }
        browsePhases[loading] = .loading
        do {
            if loading == .sets {
                async let counts = catalog.themeCounts()
                async let subs = catalog.subthemeCounts()
                setThemes = Self.group(try await counts, try await subs)
            } else {
                async let counts = catalog.minifigThemeCounts()
                async let subs = catalog.minifigSubthemeCounts()
                minifigThemes = Self.group(try await counts, try await subs)
            }
            browsePhases[loading] = .loaded
            if mode == loading { freezeOrder() } // else `modeChanged` freezes it when the user switches back
            if loading == .sets {
                await ImageLoader.shared.prefetch(setThemes.compactMap { CatalogImages.themeIconUrl($0.theme) })
            }
        } catch {
            browsePhases[loading] = .failed
        }
    }

    private static func group(_ counts: [ThemeCount], _ subs: [ThemeSubthemeCount]) -> [ThemeGroup] {
        let subsByTheme = Dictionary(grouping: subs, by: \.theme)
        return counts.filter { !$0.theme.isEmpty }.map { c in
            let subs = (subsByTheme[c.theme] ?? []).filter { !$0.subtheme.isEmpty }
            // A theme whose ONLY subtheme is the no-subtheme bucket gets no chip: it would just be the theme.
            let lone = subs.count == 1 && subs[0].subtheme == CatalogRepository.noSubtheme
            return ThemeGroup(
                theme: c.theme, count: c.count,
                subthemes: (lone ? [] : subs)
                    .sorted { $0.subtheme.lowercased() < $1.subtheme.lowercased() }
                    .map { .init(name: $0.subtheme, count: $0.count) }
            )
        }
    }

    /// ALPHABETICAL and COUNT pin favorites to the top.
    private func freezeOrder() {
        let favs = favorites
        let sorted: [ThemeGroup] = switch themeSort {
        case .count: themes.sorted { $0.count == $1.count ? $0.theme.lowercased() < $1.theme.lowercased() : $0.count > $1.count }
        case .alphabetical, .favorite: themes.sorted { $0.theme.lowercased() < $1.theme.lowercased() }
        }
        orderedThemeNames = (sorted.filter { favs.contains($0.theme) } + sorted.filter { !favs.contains($0.theme) }).map(\.theme)
        themePage = 1
    }

    /// Shows another page of themes, from the top of the list.
    func selectThemePage(_ page: Int) {
        themePage = page
        homeScrollTick += 1
    }

    func toggleFavorite(_ theme: String, mode: SearchMode? = nil) {
        switch mode ?? self.mode {
        case .sets: settings.favoriteSetThemes.formSymmetricDifference([theme])
        case .minifigs: settings.favoriteMinifigThemes.formSymmetricDifference([theme])
        }
    }

    private func modeChanged() {
        freezeOrder()
        homeScrollTick += 1
        Task { await loadBrowse() }
    }

    /// Re-selecting the Search tab always returns to the browse home.
    func resetToHome() {
        searchTask?.cancel()
        query = ""
        submittedQuery = nil
        freezeOrder()
        homeScrollTick += 1
    }

    // MARK: Global search (always sets AND minifigs, whatever the browse mode)

    private func queryChanged() {
        submittedQuery = nil
        searchTask?.cancel()
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else {
            setSuggestions = []; minifigSuggestions = []
            suggestState = .idle
            return
        }
        suggestState = .pending // the previous query's suggestions stay up meanwhile
        searchTask = Task { [catalog] in
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled else { return }
            async let sets = try? catalog.searchSets(q, limit: Self.suggestionLimit)
            async let figs = try? catalog.searchMinifigs(q, limit: Self.suggestionLimit)
            let (s, f) = await (sets, figs)
            // A newer keystroke superseded this lookup — drop the stale result.
            guard !Task.isCancelled else { return }
            // Both failing is a connection problem, not "no matches" — keep what was showing. One failing
            // still shows the other.
            guard s != nil || f != nil else { suggestState = .failed; return }
            setSuggestions = s ?? []
            minifigSuggestions = f ?? []
            suggestState = .idle
        }
    }

    func submit() {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return }
        searchTask?.cancel()
        submittedQuery = q
        resultsPhase = .loading
        searchTask = Task { [catalog] in
            do {
                async let sets = catalog.searchSets(q, limit: Self.searchLimit)
                async let figs = catalog.searchMinifigs(q, limit: Self.searchLimit)
                let (s, f) = try await (sets, figs)
                guard !Task.isCancelled else { return }
                setResults = s
                minifigResults = f
                resultsPhase = .loaded
            } catch {
                guard !Task.isCancelled else { return }
                resultsPhase = .failed
            }
        }
    }
}
