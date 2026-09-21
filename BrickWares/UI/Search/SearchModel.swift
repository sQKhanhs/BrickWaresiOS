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
        }
    }

    private(set) var setThemes: [ThemeGroup] = []
    private(set) var minifigThemes: [ThemeGroup] = []
    private(set) var browsePhase: LoadPhase = .loading
    /// Display order, **frozen** at browse entry / sort / mode change — favoriting a theme must not
    /// reorder the list under the user's finger.
    private(set) var orderedThemeNames: [String] = []

    private(set) var setSuggestions: [CatalogSet] = []
    private(set) var minifigSuggestions: [Minifig] = []
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
        guard force || themes.isEmpty else { return }
        browsePhase = .loading
        do {
            if mode == .sets {
                async let counts = catalog.themeCounts()
                async let subs = catalog.subthemeCounts()
                setThemes = Self.group(try await counts, try await subs)
            } else {
                async let counts = catalog.minifigThemeCounts()
                async let subs = catalog.minifigSubthemeCounts()
                minifigThemes = Self.group(try await counts, try await subs)
            }
            browsePhase = .loaded
            freezeOrder()
            if mode == .sets {
                await ImageLoader.shared.prefetch(setThemes.compactMap { CatalogImages.themeIconUrl($0.theme) })
            }
        } catch {
            browsePhase = .failed
        }
    }

    private static func group(_ counts: [ThemeCount], _ subs: [ThemeSubthemeCount]) -> [ThemeGroup] {
        let subsByTheme = Dictionary(grouping: subs, by: \.theme)
        return counts.filter { !$0.theme.isEmpty }.map { c in
            ThemeGroup(
                theme: c.theme, count: c.count,
                subthemes: (subsByTheme[c.theme] ?? [])
                    .filter { !$0.subtheme.isEmpty }
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
            return
        }
        searchTask = Task { [catalog] in
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled else { return }
            async let sets = try? catalog.searchSets(q, limit: Self.suggestionLimit)
            async let figs = try? catalog.searchMinifigs(q, limit: Self.suggestionLimit)
            let (s, f) = await (sets, figs)
            // A newer keystroke superseded this lookup — drop the stale result.
            guard !Task.isCancelled else { return }
            setSuggestions = s ?? []
            minifigSuggestions = f ?? []
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
