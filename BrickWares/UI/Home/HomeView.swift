import SwiftData
import SwiftUI

struct HomeView: View {
    @Environment(AuthService.self) private var auth
    @Environment(AppSettings.self) private var settings
    @Environment(AppRouter.self) private var router
    @Environment(CatalogOverlay.self) private var overlay
    @Environment(ValueService.self) private var values

    @Query(filter: #Predicate<CollectionCopy> { !$0.tombstoned }) private var copies: [CollectionCopy]

    @State private var newSets: [CatalogSet] = []
    @State private var showShare = false

    /// Signed out, the rows of the last session stay on disk but are hidden — the hero reads zero and
    /// the themes card is replaced by the sign-in prompt.
    private var items: [CollectionItem] {
        let _ = (overlay.revision, values.revision, settings.ratesRevision)
        return auth.isSignedIn ? DisplayBuilder.collectionItems(copies) : []
    }

    var body: some View {
        let items = items
        let currency = settings.currency
        let summary = CollectionStats.summary(of: items, display: currency)
        let themes = CollectionStats.themeSummaries(of: items, display: currency)

        ScrollView {
            VStack(spacing: 16) {
                HeroCard(summary: summary, currency: currency)

                HStack(spacing: 10) {
                    StatTile(value: Money.count(summary.setCount), label: L("stat_sets"))
                    StatTile(value: Money.count(summary.minifigCount), label: L("stat_minifigs"))
                    StatTile(value: Money.count(summary.pieceCount), label: L("stat_pieces"))
                }

                if !auth.isSignedIn {
                    SignInPromptCard(message: L("home_signin_prompt")).bwCard(padding: 0)
                } else if !themes.isEmpty {
                    ThemesCard(themes: themes, currency: currency)
                }

                if !newSets.isEmpty { NewSetsCard(sets: newSets) }
            }
            .padding(.horizontal, Bw.gutter)
            .padding(.bottom, 24)
        }
        .bwScreen()
        .navigationTitle(Text(verbatim: "BrickWares"))
        .toolbar {
            if auth.isSignedIn, summary.setCount + summary.minifigCount > 0 {
                ToolbarItem(placement: .primaryAction) {
                    Button { showShare = true } label: { Image(systemName: "square.and.arrow.up") }
                        .accessibilityLabel(L("home_share_cd"))
                }
            }
        }
        .sheet(isPresented: $showShare) {
            ShareCollectionSheet(items: items, summary: summary, themes: themes, memberName: auth.user?.displayName)
        }
        .task { await loadNewSets() }
        .refreshable { await loadNewSets() }
    }

    /// A random five of the current "new sets" — reshuffled on each load, like Android. Best-effort:
    /// a catalog failure just leaves the card absent.
    private func loadNewSets() async {
        guard AppConfig.isConfigured, let candidates = try? await CatalogRepository.shared.newSetCandidates() else { return }
        newSets = Array(NewSets.select(candidates).shuffled().prefix(5))
    }
}

private struct HeroCard: View {
    let summary: CollectionSummary
    let currency: AppCurrency

    /// A collection big enough to "fill the shelf" gets the brick-drop art; a small/empty one gets the
    /// lighter "no value yet" illustration (same thresholds as Android).
    private var showsDrop: Bool {
        summary.setCount > 5 || summary.minifigCount > 15 || (summary.setCount > 3 && summary.minifigCount > 10)
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            if showsDrop {
                Image("lego_drop_poster").resizable().scaledToFill()
                    .frame(maxWidth: .infinity).frame(height: 250).clipped()
            } else {
                Color(hex: 0xF4F4F2)
                Image("no_value").resizable().scaledToFit()
                    .blendMode(.multiply) // melt the illustration's own light backdrop into the card
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                    .padding(.horizontal, 70).padding(.bottom, 18)
            }
            LinearGradient(
                stops: [
                    .init(color: Color(hex: 0x1A1A1A).opacity(0.82), location: 0),
                    .init(color: Color(hex: 0x1A1A1A).opacity(0.15), location: 0.42),
                    .init(color: Color(hex: 0x1A1A1A).opacity(0.10), location: 1),
                ],
                startPoint: .top, endPoint: .bottom
            )
            VStack(alignment: .leading, spacing: 8) {
                Text(L("home_collection_value").uppercased())
                    .font(.caption.weight(.heavy)).tracking(0.8).foregroundStyle(Bw.yellow)
                Text(Money.formatIn(summary.collectionValue, currency))
                    .font(.system(size: 36, weight: .heavy, design: .rounded))
                    .foregroundStyle(.white)
                    .minimumScaleFactor(0.5).lineLimit(1)
                    .contentTransition(.numericText())
                    .shadow(color: .black.opacity(0.5), radius: 6, y: 2)
                HStack(spacing: 8) {
                    Text(L("home_paid_pill", Money.formatIn(summary.paid, currency)))
                        .font(.caption.weight(.semibold)).foregroundStyle(.white)
                        .padding(.horizontal, 10).padding(.vertical, 5)
                        .background(.black.opacity(0.4), in: Capsule())
                    heroGrowth
                        .padding(.horizontal, 10).padding(.vertical, 5)
                        .background(.black.opacity(0.5), in: Capsule())
                }
            }
            .padding(22)
        }
        .frame(height: 250)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .animation(.snappy, value: summary.collectionValue)
        .accessibilityElement(children: .combine)
    }

    private var heroGrowth: some View {
        let p = (summary.growthPercent * 10).rounded() / 10
        let color: Color = p > 0 ? Color(hex: 0x4ADE80) : (p < 0 ? Color(hex: 0xF87171) : .white)
        let text = p > 0 ? L("growth_up", Money.oneDecimalTrimmed(p)) : (p < 0 ? L("growth_down", Money.oneDecimalTrimmed(p)) : L("growth_flat"))
        return Text(text).font(.caption.weight(.semibold)).foregroundStyle(color)
    }
}

private struct ThemesCard: View {
    let themes: [ThemeSummary]
    let currency: AppCurrency

    var body: some View {
        let maxValue = max(themes.map(\.totalValue).max() ?? 1, 1)
        VStack(alignment: .leading, spacing: 14) {
            SectionHeader(title: L("home_collection_by_theme"))
            ForEach(themes) { theme in
                VStack(spacing: 6) {
                    HStack {
                        Text(theme.theme.isEmpty ? "—" : theme.theme).font(.subheadline.weight(.semibold)).lineLimit(1)
                        Spacer()
                        Text(verbatim: "\(theme.setCount) · \(Money.formatIn(theme.totalValue, currency))")
                            .font(.caption).foregroundStyle(Bw.textMuted)
                    }
                    GeometryReader { geo in
                        let fraction = min(max(Double(theme.totalValue) / Double(maxValue), 0.02), 1)
                        ZStack(alignment: .leading) {
                            Capsule().fill(Bw.track)
                            Capsule().fill(Bw.yellow).frame(width: geo.size.width * fraction)
                        }
                    }
                    .frame(height: 6)
                }
            }
        }
        .bwCard(padding: 16)
    }
}

private struct NewSetsCard: View {
    let sets: [CatalogSet]
    @Environment(AppRouter.self) private var router

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeader(title: L("home_new_sets_title"), subtitle: L("home_new_sets_subtitle"))
            ForEach(sets) { set in
                Button { router.open(.set(set.id)) } label: {
                    HStack(alignment: .top, spacing: 12) {
                        ItemThumb(urls: set.cardImageUrls, size: 56)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(verbatim: "\(set.setNumber) \(set.name)")
                                .font(.subheadline.weight(.bold)).foregroundStyle(Bw.link)
                                .multilineTextAlignment(.leading).lineLimit(2)
                            MetaLine(L("meta_theme"), set.theme)
                            MetaLine(L("meta_pieces_minifigs"), "\(Money.count(set.pieces)) / \(set.minifigs)")
                            HStack(spacing: 8) {
                                MetaLine(L("meta_release"), releaseLabel(year: set.releaseYear, month: set.releaseMonth))
                                StatusBadge(status: set.status)
                            }
                        }
                        Spacer(minLength: 0)
                    }
                }
                .buttonStyle(.plain)
            }
            Divider()
            Button { router.open(.newSets) } label: {
                HStack {
                    Spacer()
                    Text(L("home_new_sets_view_more")).font(.subheadline.weight(.semibold))
                    Image(systemName: "arrow.right").font(.subheadline.weight(.semibold))
                    Spacer()
                }
                .foregroundStyle(Bw.link)
            }
            .buttonStyle(.plain)
        }
        .bwCard(padding: 16)
    }
}

/// The full "New Sets" page: grouped by theme A→Z, each theme newest-first.
struct NewSetsView: View {
    @State private var groups: [(theme: String, sets: [CatalogSet])] = []
    @State private var phase: LoadPhase = .loading

    var body: some View {
        ScrollView {
            switch phase {
            case .loading:
                ProgressView().tint(Bw.yellow).frame(maxWidth: .infinity).padding(.top, 80)
            case .failed:
                ErrorStateView { Task { await load() } }
            case .loaded:
                LazyVStack(alignment: .leading, spacing: 12, pinnedViews: [.sectionHeaders]) {
                    Text(L("new_sets_count", groups.reduce(0) { $0 + $1.sets.count }))
                        .font(.caption.weight(.bold)).foregroundStyle(Bw.textMuted)
                    ForEach(groups, id: \.theme) { group in
                        Section {
                            ForEach(group.sets) { SetResultCard(set: $0) }
                        } header: {
                            Text(group.theme).font(.headline)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.vertical, 8).background(Bw.bg)
                        }
                    }
                }
                .padding(.horizontal, Bw.gutter).padding(.bottom, 24)
            }
        }
        .bwScreen()
        .navigationTitle(L("new_sets_title"))
        .navigationBarTitleDisplayMode(.inline)
        .itemSheets()
        .task { if groups.isEmpty { await load() } }
    }

    private func load() async {
        phase = .loading
        do {
            groups = NewSets.groupedByTheme(try await CatalogRepository.shared.newSetCandidates())
            phase = .loaded
        } catch {
            phase = .failed
        }
    }
}

enum LoadPhase { case loading, loaded, failed }
