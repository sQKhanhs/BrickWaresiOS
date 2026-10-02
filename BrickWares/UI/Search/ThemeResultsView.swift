import SwiftUI

enum ThemeDetailSort: String, CaseIterable, Identifiable {
    case newest, oldest, priceHigh, priceLow, name
    var id: String { rawValue }

    var label: String {
        switch self {
        case .newest: L("sort_newest")
        case .oldest: L("sort_oldest")
        case .priceHigh: L("sort_price_high")
        case .priceLow: L("sort_price_low")
        case .name: L("sort_name")
        }
    }
}

/// Minifigs have no release date or retail price, so they sort differently.
enum MinifigSort: String, CaseIterable, Identifiable {
    case name, valueHigh, valueLow, mostSets
    var id: String { rawValue }

    var label: String {
        switch self {
        case .name: L("sort_name")
        case .valueHigh: L("sort_value_high")
        case .valueLow: L("sort_value_low")
        case .mostSets: L("sort_most_sets")
        }
    }
}

/// One theme's sets (or minifigs). The theme is fetched on demand — the catalog is never held in
/// memory — then the subtheme filter and sort run over that bounded list. Each pushed page owns its
/// own state, so a deeper hop never replaces another page's results.
struct ThemeResultsView: View {
    let theme: String
    let initialSubtheme: String?
    let minifigMode: Bool

    @Environment(AppSettings.self) private var settings
    @Environment(ValueService.self) private var values

    private static let allSubthemes = "__all"

    @State private var sets: [CatalogSet] = []
    @State private var figs: [Minifig] = []
    @State private var phase: LoadPhase = .loading
    @State private var subtheme: String
    @State private var sort: ThemeDetailSort = .newest
    @State private var figSort: MinifigSort = .name
    /// Numbered pages, ten cards each; a subtheme or sort change goes back to the first.
    @State private var page = 1

    private static let topID = "theme-results-top"

    init(theme: String, initialSubtheme: String?, minifigMode: Bool) {
        self.theme = theme
        self.initialSubtheme = initialSubtheme
        self.minifigMode = minifigMode
        _subtheme = State(initialValue: initialSubtheme ?? Self.allSubthemes)
    }

    private var subthemeOptions: [String] {
        let names = minifigMode
            ? figs.flatMap { $0.themeSubthemes.filter { $0.theme == theme }.map(\.subtheme) }
            : sets.map(\.subtheme)
        return [Self.allSubthemes] + Set(names).sorted { $0.lowercased() < $1.lowercased() }
    }

    private var visibleSets: [CatalogSet] {
        let filtered = subtheme == Self.allSubthemes ? sets : sets.filter { $0.subtheme == subtheme }
        func release(_ s: CatalogSet) -> Int { s.releaseYear * 100 + s.releaseMonth }
        return switch sort {
        case .newest: filtered.sorted { release($0) == release($1) ? $0.setNumber < $1.setNumber : release($0) > release($1) }
        case .oldest: filtered.sorted { release($0) == release($1) ? $0.setNumber < $1.setNumber : release($0) < release($1) }
        // Sets without a retail price go last in both price orders.
        case .priceHigh: filtered.sorted { ($0.retailPrice ?? -1) > ($1.retailPrice ?? -1) }
        case .priceLow: filtered.sorted { ($0.retailPrice ?? .max) < ($1.retailPrice ?? .max) }
        case .name: filtered.sorted { $0.name.lowercased() < $1.name.lowercased() }
        }
    }

    private var visibleFigs: [Minifig] {
        let filtered = subtheme == Self.allSubthemes
            ? figs
            : figs.filter { $0.themeSubthemes.contains { $0.theme == theme && $0.subtheme == subtheme } }
        func value(_ f: Minifig) -> Int64? { values.value(forFig: f.figNum)?.amountUsdCents }
        return switch figSort {
        case .name: filtered.sorted { $0.name.lowercased() < $1.name.lowercased() }
        case .valueHigh: filtered.sorted { (value($0) ?? -1) > (value($1) ?? -1) }
        case .valueLow: filtered.sorted { (value($0) ?? .max) < (value($1) ?? .max) }
        case .mostSets: filtered.sorted { $0.setCount > $1.setCount }
        }
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                switch phase {
                case .loading:
                    ProgressView().tint(Bw.yellow).frame(maxWidth: .infinity).padding(.top, 80)
                case .failed:
                    ErrorStateView { Task { await load() } }
                case .loaded:
                    // The count, subtheme filter and sort stay pinned above the cards (on Android they
                    // sit outside the list altogether).
                    LazyVStack(spacing: 12, pinnedViews: [.sectionHeaders]) {
                        Section {
                            let total = minifigMode ? visibleFigs.count : visibleSets.count
                            if minifigMode {
                                ForEach(Pagination.items(visibleFigs, page: page)) { MinifigCard(fig: $0) }
                            } else {
                                ForEach(Pagination.items(visibleSets, page: page)) { SetResultCard(set: $0) }
                            }
                            PaginationBar(
                                currentPage: Pagination.clamp(page, total: total),
                                totalPages: Pagination.pageCount(of: total)
                            ) { page = $0 }
                        } header: {
                            controls.pinnedControls(inList: false)
                        }
                    }
                    .id(Self.topID)
                    .padding(.horizontal, Bw.gutter).padding(.bottom, 24)
                }
            }
            .opaqueTopBar()
            .onChange(of: page) { _, _ in proxy.scrollTo(Self.topID, anchor: .top) }
            .onChange(of: subtheme) { _, _ in page = 1 }
            .onChange(of: sort) { _, _ in page = 1 }
            .onChange(of: figSort) { _, _ in page = 1 }
        }
        .bwScreen()
        .navigationTitle(theme)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { ToolbarItem(placement: .primaryAction) { favoriteButton } }
        .itemSheets()
        .task { if sets.isEmpty, figs.isEmpty { await load() } }
    }

    private var controls: some View {
        VStack(alignment: .leading, spacing: 10) {
            let count = minifigMode ? visibleFigs.count : visibleSets.count
            Text(minifigMode ? L("search_minifig_count", count) : L("search_results_sets", count))
                .font(.caption.weight(.bold)).foregroundStyle(Bw.textMuted)
            HStack(spacing: 8) {
                if subthemeOptions.count > 2 {
                    OptionMenu(
                        title: L("meta_subtheme"), options: subthemeOptions, selection: $subtheme,
                        label: { $0 == Self.allSubthemes ? L("search_all_subthemes") : $0 },
                        systemImage: "line.3.horizontal.decrease"
                    )
                }
                Spacer(minLength: 0)
                if minifigMode {
                    OptionMenu(title: L("search_sort_label"), options: MinifigSort.allCases, selection: $figSort, label: \.label)
                } else {
                    OptionMenu(title: L("search_sort_label"), options: ThemeDetailSort.allCases, selection: $sort, label: \.label)
                }
            }
        }
    }

    private var favoriteButton: some View {
        let isFav = (minifigMode ? settings.favoriteMinifigThemes : settings.favoriteSetThemes).contains(theme)
        return Button {
            if minifigMode {
                settings.favoriteMinifigThemes.formSymmetricDifference([theme])
            } else {
                settings.favoriteSetThemes.formSymmetricDifference([theme])
            }
        } label: {
            Image(systemName: isFav ? "star.fill" : "star").foregroundStyle(isFav ? Bw.yellow : Bw.textMuted)
        }
        .sensoryFeedback(.selection, trigger: isFav)
        .accessibilityLabel(isFav ? L("search_unmark_favorite_cd") : L("search_mark_favorite_cd"))
    }

    private func load() async {
        phase = .loading
        do {
            if minifigMode {
                figs = try await CatalogRepository.shared.minifigsInTheme(theme)
            } else {
                sets = try await CatalogRepository.shared.setsInTheme(theme)
            }
            // A deep-linked subtheme that no longer exists falls back to "all".
            if !subthemeOptions.contains(subtheme) { subtheme = Self.allSubthemes }
            phase = .loaded
        } catch is CancellationError {
            // navigated away mid-load
        } catch {
            phase = .failed
        }
    }
}
