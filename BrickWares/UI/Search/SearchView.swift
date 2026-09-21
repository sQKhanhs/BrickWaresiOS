import SwiftUI

struct SearchView: View {
    @Environment(AppRouter.self) private var router
    @Environment(AppSettings.self) private var settings
    @State private var model = SearchModel()

    private let topID = "search-top"

    var body: some View {
        @Bindable var model = model
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 12) {
                    Color.clear.frame(height: 0).id(topID)
                    if model.showBrowse {
                        browse
                    } else if model.showSuggestions {
                        suggestions
                    } else {
                        results
                    }
                }
                .padding(.horizontal, Bw.gutter)
                .padding(.bottom, 24)
            }
            .scrollDismissesKeyboard(.immediately)
            // Scroll home only on an explicit reset (mode toggle / tab re-tap) — plain back-navigation
            // leaves the tick unchanged, so the previous scroll position is restored.
            .onChange(of: model.homeScrollTick) { _, _ in withAnimation { proxy.scrollTo(topID, anchor: .top) } }
        }
        .bwScreen()
        .navigationTitle(model.mode == .sets ? L("search_title") : L("search_title_minifigs"))
        .searchable(text: $model.query, placement: .navigationBarDrawer(displayMode: .always), prompt: L("search_placeholder"))
        .autocorrectionDisabled()
        .textInputAutocapitalization(.never)
        .onSubmit(of: .search) { model.submit() }
        .itemSheets()
        .task { await model.loadBrowse() }
        .onChange(of: router.searchResetTick) { _, _ in model.resetToHome() }
    }

    // MARK: Browse home

    @ViewBuilder private var browse: some View {
        @Bindable var model = model
        BannerImage(name: "search_banner")

        HStack(spacing: 8) {
            Picker("", selection: $model.mode) {
                Text(L("stat_sets")).tag(SearchMode.sets)
                Text(L("stat_minifigs")).tag(SearchMode.minifigs)
            }
            .pickerStyle(.segmented)
            .accessibilityLabel(L("search_toggle_minifigs_cd"))

            OptionMenu(
                title: L("search_sort_label"),
                options: model.viewMode == .list ? [.alphabetical, .favorite] : ThemeSort.allCases,
                selection: $model.themeSort, label: \.label
            )

            Button {
                withAnimation(.snappy) { model.viewMode = model.viewMode == .detail ? .list : .detail }
            } label: {
                Image(systemName: model.viewMode == .detail ? "square.grid.2x2" : "list.bullet.rectangle")
                    .font(.subheadline.weight(.semibold)).foregroundStyle(Bw.textSecondary)
                    .padding(8).background(Bw.surface, in: Circle()).overlay(Circle().strokeBorder(Bw.border))
            }
            .accessibilityLabel(model.viewMode == .detail ? L("search_view_list_cd") : L("search_view_detail_cd"))
        }

        switch model.browsePhase {
        case .loading:
            ProgressView().tint(Bw.yellow).padding(.top, 50)
        case .failed:
            ErrorStateView { Task { await model.loadBrowse(force: true) } }
        case .loaded:
            let themes = model.orderedThemes
            if themes.isEmpty {
                Text(model.themeSort == .favorite ? L("search_no_favorite_themes") : L("search_minifig_empty"))
                    .font(.subheadline).foregroundStyle(Bw.textMuted).multilineTextAlignment(.center).padding(.top, 40)
            } else if model.viewMode == .detail {
                ForEach(themes) { ThemeCard(group: $0, model: model) }
            } else {
                LazyVGrid(columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible())], spacing: 10) {
                    ForEach(themes) { ThemeListCard(group: $0, model: model) }
                }
            }
        }
    }

    // MARK: Live suggestions

    @ViewBuilder private var suggestions: some View {
        let sets = model.setSuggestions
        let figs = model.minifigSuggestions
        if sets.isEmpty, figs.isEmpty {
            Text(L("search_no_matches", model.query)).font(.subheadline).foregroundStyle(Bw.textMuted).padding(.top, 30)
        } else {
            VStack(alignment: .leading, spacing: 0) {
                if !sets.isEmpty {
                    suggestionHeader(L("search_suggestions_sets"))
                    ForEach(sets) { set in
                        suggestionRow(image: set.cardImageUrls, title: "\(set.setNumber) \(set.name)", subtitle: set.theme) {
                            router.open(.set(set.id))
                        }
                    }
                }
                if !figs.isEmpty {
                    suggestionHeader(L("search_suggestions_minifigs"))
                    ForEach(figs) { fig in
                        suggestionRow(image: [fig.imageUrl], title: fig.name, subtitle: fig.figNum) {
                            router.open(.minifig(fig.figNum))
                        }
                    }
                }
            }
            .bwCard(padding: 6)
        }
    }

    private func suggestionHeader(_ text: String) -> some View {
        Text(text.uppercased()).font(.caption2.weight(.heavy)).foregroundStyle(Bw.textMuted)
            .padding(.horizontal, 10).padding(.top, 10).padding(.bottom, 4)
    }

    private func suggestionRow(image: [String?], title: String, subtitle: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 10) {
                ItemThumb(urls: image, size: 40)
                VStack(alignment: .leading, spacing: 1) {
                    Text(title).font(.subheadline.weight(.semibold)).foregroundStyle(Bw.text).lineLimit(1)
                    Text(subtitle).font(.caption).foregroundStyle(Bw.textMuted).lineLimit(1)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right").font(.caption.weight(.bold)).foregroundStyle(Bw.textFaint)
            }
            .padding(.horizontal, 10).padding(.vertical, 7)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: Submitted results

    @ViewBuilder private var results: some View {
        let q = model.submittedQuery ?? ""
        switch model.resultsPhase {
        case .loading:
            ProgressView().tint(Bw.yellow).padding(.top, 50)
        case .failed:
            ErrorStateView { model.submit() }
        case .loaded:
            if model.tooMany {
                TooManyResults(query: q)
            } else if model.setResults.isEmpty, model.minifigResults.isEmpty {
                EmptyStateView(message: L("search_no_results", q))
            } else {
                Text(L("search_results_for", q, model.setResults.count + model.minifigResults.count))
                    .font(.subheadline.weight(.semibold)).frame(maxWidth: .infinity, alignment: .leading)
                if !model.setResults.isEmpty {
                    SectionHeader(title: L("search_results_sets", model.setResults.count))
                    ForEach(model.setResults) { SetResultCard(set: $0) }
                }
                if !model.minifigResults.isEmpty {
                    SectionHeader(title: L("search_results_minifigs", model.minifigResults.count))
                    ForEach(model.minifigResults) { MinifigCard(fig: $0) }
                }
            }
        }
    }
}

private struct TooManyResults: View {
    let query: String

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(L("search_too_many", query)).font(.subheadline.weight(.semibold))
            Divider()
            Text(L("search_tips_title")).font(.headline)
            ForEach(["search_tip_1", "search_tip_2", "search_tip_3", "search_tip_4"], id: \.self) { key in
                Label { Text(L(key)).font(.subheadline) } icon: { Image(systemName: "lightbulb").foregroundStyle(Bw.link2) }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .bwCard(padding: 16)
    }
}

// MARK: - Theme cards

private struct ThemeIcon: View {
    let theme: String
    var size: CGFloat = 46

    var body: some View {
        RemoteImage([CatalogImages.themeIconUrl(theme)?.absoluteString], maxPointSize: size * 2, hidesOnFailure: true)
            .frame(width: size * 1.6, height: size)
            .accessibilityHidden(true)
    }
}

private struct FavoriteStar: View {
    let theme: String
    let model: SearchModel

    var body: some View {
        let isFav = model.favorites.contains(theme)
        Button { model.toggleFavorite(theme) } label: {
            Image(systemName: isFav ? "star.fill" : "star")
                .font(.body).foregroundStyle(isFav ? Bw.yellow : Bw.textFaint)
                .frame(width: 36, height: 36).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .sensoryFeedback(.selection, trigger: isFav)
        .accessibilityLabel(isFav ? L("search_unmark_favorite_cd") : L("search_mark_favorite_cd"))
    }
}

private struct ThemeCard: View {
    let group: ThemeGroup
    let model: SearchModel
    @Environment(AppRouter.self) private var router

    private var isMinifigs: Bool { model.mode == .minifigs }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                Button { router.open(.theme(name: group.theme, subtheme: nil, minifigs: isMinifigs)) } label: {
                    HStack(spacing: 12) {
                        if !isMinifigs { ThemeIcon(theme: group.theme) }
                        VStack(alignment: .leading, spacing: 1) {
                            Text(group.theme).font(.headline).foregroundStyle(Bw.text).multilineTextAlignment(.leading)
                            Text(verbatim: "(\(Money.count(group.count)))").font(.caption).foregroundStyle(Bw.textMuted)
                        }
                        Spacer(minLength: 0)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                FavoriteStar(theme: group.theme, model: model)
            }
            if !group.subthemes.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(group.subthemes, id: \.self) { sub in
                            Button { router.open(.theme(name: group.theme, subtheme: sub.name, minifigs: isMinifigs)) } label: {
                                Text(verbatim: "\(sub.name) (\(sub.count))")
                                    .font(.caption.weight(.medium)).foregroundStyle(Bw.textSecondary)
                                    .padding(.horizontal, 10).padding(.vertical, 5)
                                    .background(Bw.surface, in: Capsule()).overlay(Capsule().strokeBorder(Bw.border))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
        }
        .bwCard()
    }
}

private struct ThemeListCard: View {
    let group: ThemeGroup
    let model: SearchModel
    @Environment(AppRouter.self) private var router

    var body: some View {
        Button { router.open(.theme(name: group.theme, subtheme: nil, minifigs: model.mode == .minifigs)) } label: {
            VStack(spacing: 8) {
                if model.mode == .sets { ThemeIcon(theme: group.theme, size: 38) }
                Text(group.theme).font(.subheadline.weight(.semibold)).foregroundStyle(Bw.text)
                    .multilineTextAlignment(.center).lineLimit(2).minimumScaleFactor(0.85)
            }
            .frame(maxWidth: .infinity, minHeight: 86)
        }
        .buttonStyle(.plain)
        .bwCard(padding: 10)
        .overlay(alignment: .topTrailing) {
            if model.favorites.contains(group.theme) {
                Image(systemName: "star.fill").font(.caption2).foregroundStyle(Bw.yellow).padding(8)
            }
        }
    }
}
