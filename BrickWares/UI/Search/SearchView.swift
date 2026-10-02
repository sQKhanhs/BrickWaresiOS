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
                    // Banner then search field — the banner is always the first (scrolling) item and the
                    // field sits right under it, matching Android; keeping the field unconditional here
                    // preserves its first-responder as browse/suggestions/results swap below.
                    BannerImage(name: "search_banner",
                                title: model.mode == .sets ? L("search_title") : L("search_title_minifigs"))
                    SearchField(text: $model.query, prompt: L("search_placeholder")) { model.submit() }
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
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
        .itemSheets()
        .task { await model.loadBrowse() }
        .onChange(of: router.searchResetTick) { _, _ in model.resetToHome() }
    }

    // MARK: Browse home

    @ViewBuilder private var browse: some View {
        @Bindable var model = model
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
            // "No matches" only once a lookup for THIS query has actually come back empty.
            switch model.suggestState {
            case .pending:
                HStack(spacing: 8) {
                    ProgressView().tint(Bw.yellow)
                    Text(L("search_searching")).font(.subheadline).foregroundStyle(Bw.textMuted)
                }
                .padding(.top, 30)
            case .failed:
                Text(L("search_suggest_error")).font(.subheadline).foregroundStyle(Bw.textMuted)
                    .multilineTextAlignment(.center).padding(.top, 30)
            case .idle:
                Text(L("search_no_matches", model.query)).font(.subheadline).foregroundStyle(Bw.textMuted).padding(.top, 30)
            }
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

/// The in-content search bar (replaces `.searchable` so it can sit under the banner, like Android).
private struct SearchField: View {
    @Binding var text: String
    var prompt: String
    var onSubmit: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").font(.subheadline).foregroundStyle(Bw.textMuted)
            TextField(prompt, text: $text)
                .textFieldStyle(.plain)
                .foregroundStyle(Bw.text)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                .submitLabel(.search)
                .onSubmit(onSubmit)
            if !text.isEmpty {
                Button { text = "" } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(Bw.textFaint)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(L("search_clear_cd"))
            }
        }
        .padding(.horizontal, 12).frame(height: 44)
        .background(Bw.surface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Bw.border))
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

/// Themes found to have no logo this session, so a card that scrolls back in doesn't flash an empty box
/// again while the loader re-confirms it.
@MainActor private enum ThemeLogoMemo {
    static var missing = Set<String>()
}

/// A theme's logo in its box (card colour, soft border) — Android's `ThemeLogoBox`. A theme without an
/// uploaded logo shows NO box at all (Android prints a "logo" placeholder there; the owner prefers it
/// gone on iOS).
private struct ThemeLogo: View {
    let theme: String
    var width: CGFloat = 140
    var height: CGFloat = 80
    var corner: CGFloat = 8
    var inset: CGFloat = 10

    @State private var missing: Bool

    init(theme: String, width: CGFloat = 140, height: CGFloat = 80, corner: CGFloat = 8, inset: CGFloat = 10) {
        self.theme = theme
        self.width = width
        self.height = height
        self.corner = corner
        self.inset = inset
        _missing = State(initialValue: ThemeLogoMemo.missing.contains(theme))
    }

    var body: some View {
        if !missing, let url = CatalogImages.themeIconUrl(theme)?.absoluteString {
            RemoteImage([url], maxPointSize: width, hidesOnFailure: true) { loaded in
                guard !loaded else { return }
                ThemeLogoMemo.missing.insert(theme)
                missing = true
            }
            .padding(inset)
            .frame(width: width, height: height)
            .background(Bw.card, in: RoundedRectangle(cornerRadius: corner, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: corner, style: .continuous).strokeBorder(Bw.borderSoft))
            .accessibilityHidden(true)
        }
    }
}

/// Items in wrapping rows, each row centred — Compose's `FlowRow` with a centred arrangement.
private struct CenteredFlow: Layout {
    var spacing: CGFloat = 10
    var lineSpacing: CGFloat = 2

    private struct Line {
        var items: [(index: Int, size: CGSize)] = []
        var width: CGFloat = 0
        var height: CGFloat = 0
    }

    private func lines(_ subviews: Subviews, in width: CGFloat) -> [Line] {
        var lines = [Line()]
        for (index, subview) in subviews.enumerated() {
            var size = subview.sizeThatFits(.unspecified)
            if size.width > width { size = subview.sizeThatFits(ProposedViewSize(width: width, height: nil)) }
            let gap = lines[lines.count - 1].items.isEmpty ? 0 : spacing
            if !lines[lines.count - 1].items.isEmpty, lines[lines.count - 1].width + gap + size.width > width {
                lines.append(Line())
            }
            let extra = lines[lines.count - 1].items.isEmpty ? 0 : spacing
            lines[lines.count - 1].items.append((index, size))
            lines[lines.count - 1].width += extra + size.width
            lines[lines.count - 1].height = max(lines[lines.count - 1].height, size.height)
        }
        return lines.filter { !$0.items.isEmpty }
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .greatestFiniteMagnitude
        let lines = lines(subviews, in: width)
        let height = lines.reduce(0) { $0 + $1.height } + lineSpacing * CGFloat(max(lines.count - 1, 0))
        return CGSize(width: proposal.width ?? (lines.map(\.width).max() ?? 0), height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for line in lines(subviews, in: bounds.width) {
            var x = bounds.minX + (bounds.width - line.width) / 2
            for item in line.items {
                subviews[item.index].place(
                    at: CGPoint(x: x, y: y + line.height / 2), anchor: .leading,
                    proposal: ProposedViewSize(width: item.size.width, height: item.size.height)
                )
                x += item.size.width + spacing
            }
            y += line.height + lineSpacing
        }
    }
}

private struct FavoriteStar: View {
    let theme: String
    let model: SearchModel
    /// The grid card's star is a size smaller; its tap area stays thumb-sized.
    var compact = false

    var body: some View {
        let isFav = model.favorites.contains(theme)
        Button { model.toggleFavorite(theme) } label: {
            Image(systemName: isFav ? "star.fill" : "star")
                .font(compact ? .footnote : .body).foregroundStyle(isFav ? Bw.yellow : Bw.textFaint)
                .frame(width: compact ? 32 : 36, height: compact ? 32 : 36).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .sensoryFeedback(.selection, trigger: isFav)
        .accessibilityLabel(isFav ? L("search_unmark_favorite_cd") : L("search_mark_favorite_cd"))
    }
}

/// A theme in the browse list — Android's `ThemeCard`: the logo big and centred on top, the name and
/// count under it, then the subthemes as links wrapping over as many centred rows as they need (they
/// used to be chips in a sideways scroller, most of them off screen). The star sits in the top-right
/// corner. (Internal so it can be rendered on its own.)
struct ThemeCard: View {
    let group: ThemeGroup
    let model: SearchModel
    @Environment(AppRouter.self) private var router

    private var isMinifigs: Bool { model.mode == .minifigs }
    private let shape = RoundedRectangle(cornerRadius: 14, style: .continuous)

    private func open(subtheme: String? = nil) {
        router.open(.theme(name: group.theme, subtheme: subtheme, minifigs: isMinifigs))
    }

    var body: some View {
        VStack(spacing: 10) {
            Button { open() } label: {
                VStack(spacing: 10) {
                    ThemeLogo(theme: group.theme)
                    (Text(group.theme).font(.headline).foregroundStyle(Bw.text)
                        + Text(verbatim: "  (\(Money.count(group.count)))").font(.footnote).foregroundStyle(Bw.textMuted))
                        .multilineTextAlignment(.center)
                        // Clear of the star when there is no logo above to push the name down.
                        .padding(.horizontal, 26)
                }
                .frame(maxWidth: .infinity)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if !group.subthemes.isEmpty {
                CenteredFlow {
                    ForEach(group.subthemes, id: \.self) { sub in
                        Button { open(subtheme: sub.name) } label: {
                            Text(verbatim: "\(sub.name) (\(sub.count))")
                                .font(.caption).foregroundStyle(Bw.link)
                                .padding(.horizontal, 2).padding(.vertical, 4)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 20).padding(.horizontal, 16)
        .background(Bw.surface, in: shape)
        // The rest of the card opens the theme too, as on Android.
        .contentShape(shape)
        .onTapGesture { open() }
        .overlay(alignment: .topTrailing) { FavoriteStar(theme: group.theme, model: model).padding(4) }
    }
}

/// A theme in the compact two-column grid: a small logo above the name, and the favourite star in the
/// corner — a toggle, as on Android (it used to be a marker shown only on themes already starred, so
/// there was no way to star one from the grid).
private struct ThemeListCard: View {
    let group: ThemeGroup
    let model: SearchModel
    @Environment(AppRouter.self) private var router

    var body: some View {
        Button { router.open(.theme(name: group.theme, subtheme: nil, minifigs: model.mode == .minifigs)) } label: {
            VStack(spacing: 8) {
                ThemeLogo(theme: group.theme, width: 84, height: 48, corner: 6, inset: 6)
                Text(group.theme).font(.subheadline.weight(.semibold)).foregroundStyle(Bw.text)
                    .multilineTextAlignment(.center).lineLimit(2).minimumScaleFactor(0.85)
            }
            .frame(maxWidth: .infinity, minHeight: 86)
        }
        .buttonStyle(.plain)
        .bwCard(padding: 10)
        .overlay(alignment: .topTrailing) { FavoriteStar(theme: group.theme, model: model, compact: true) }
    }
}
