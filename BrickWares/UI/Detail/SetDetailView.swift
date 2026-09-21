import SwiftData
import SwiftUI

struct SetDetailView: View {
    let catalogKey: String

    @Environment(AppSettings.self) private var settings
    @Environment(AppRouter.self) private var router
    @Environment(AuthService.self) private var auth
    @Environment(Connectivity.self) private var connectivity
    @Environment(OwnershipIndex.self) private var ownership
    @Environment(ValueService.self) private var values
    @Environment(CatalogOverlay.self) private var overlay

    @Query private var copyRows: [CollectionCopy]

    @State private var set: CatalogSet?
    @State private var phase: LoadPhase = .loading
    @State private var minifigs: [Minifig] = []
    @State private var related: [CatalogSet] = []
    @State private var currentValue: CurrentValue?
    @State private var valueLoading = true
    @State private var heroLoaded = false

    init(catalogKey: String) {
        self.catalogKey = catalogKey
        // Owned copies of this set number (the bare number = everything before a "-<variant>" suffix).
        let number = Self.bareNumber(catalogKey)
        _copyRows = Query(filter: #Predicate<CollectionCopy> { $0.setNumber == number && !$0.tombstoned })
    }

    private static func bareNumber(_ key: String) -> String {
        guard let dash = key.lastIndex(of: "-"), dash != key.startIndex, Int(key[key.index(after: dash)...]) != nil else { return key }
        return String(key[..<dash])
    }

    var body: some View {
        ScrollView {
            switch phase {
            case .loading:
                ProgressView().tint(Bw.yellow).frame(maxWidth: .infinity).padding(.top, 100)
            case .failed:
                if connectivity.isOnline {
                    ErrorStateView { Task { await load() } }
                } else {
                    ErrorStateView(message: L("detail_no_internet")) { Task { await load() } }
                }
            case .loaded:
                if let set {
                    content(set)
                } else {
                    EmptyStateView(message: L("detail_set_not_found"), image: "error_state")
                }
            }
        }
        .bwScreen()
        .navigationTitle(set.map { "\($0.setNumber) \($0.name)" } ?? Self.bareNumber(catalogKey))
        .navigationBarTitleDisplayMode(.inline)
        .itemSheets()
        .task(id: catalogKey) { await load() }
        // Re-fetch shortly after the user contributes a price, once the sync has published it.
        .onChange(of: copyRows.map(\.updatedAt)) { _, _ in Task { await refreshValueSoon() } }
    }

    @ViewBuilder private func content(_ set: CatalogSet) -> some View {
        VStack(spacing: 16) {
            Hero(set: set, heroLoaded: $heroLoaded)
            detailsCard(set)
            pricingCard(set)
            if !minifigs.isEmpty { minifigGrid }
            if !related.isEmpty {
                SectionHeader(title: L("detail_more_in", set.theme))
                ForEach(related) { SetResultCard(set: $0) }
            }
        }
        .padding(.horizontal, Bw.gutter).padding(.bottom, 28)
    }

    private func detailsCard(_ set: CatalogSet) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            SectionHeader(title: L("detail_set_details")).padding(.bottom, 6)
            DetailRow(L("detail_set_number"), value: set.setNumber)
            Divider()
            DetailRow(L("detail_name"), value: set.name)
            Divider()
            DetailRow(label: L("meta_theme")) { link(set.theme) { router.open(.theme(name: set.theme, subtheme: nil, minifigs: false)) } }
            Divider()
            DetailRow(label: L("meta_subtheme")) { link(set.subtheme) { router.open(.theme(name: set.theme, subtheme: set.subtheme, minifigs: false)) } }
            Divider()
            DetailRow(L("detail_released"), value: releaseLabel(year: set.releaseYear, month: set.releaseMonth))
            Divider()
            DetailRow(label: L("detail_availability")) { StatusBadge(status: set.status) }
            if set.status == .retired, set.retiredYear > 0 {
                Divider()
                DetailRow(L("detail_retired"), value: releaseLabel(year: set.retiredYear, month: set.retiredMonth))
            }
            Divider()
            DetailRow(L("stat_pieces"), value: Money.count(set.pieces))
            Divider()
            DetailRow(L("stat_minifigs"), value: String(set.minifigs))
        }
        .bwCard(padding: 16)
    }

    private func pricingCard(_ set: CatalogSet) -> some View {
        let currency = settings.currency
        let owned = copyRows.isEmpty ? nil : DisplayBuilder.collectionItem(copyRows)
        // Brickset's note, in Vietnamese when the app runs in Vietnamese and a translation exists.
        let isVietnamese = Locale.current.language.languageCode?.identifier == "vi"
        let note = (isVietnamese ? set.notesVi : nil) ?? set.notes
        return VStack(alignment: .leading, spacing: 0) {
            SectionHeader(title: L("detail_pricing")).padding(.bottom, 6)
            DetailRow(label: L("price_retail")) {
                Text(set.retailPrice.map { Money.format(usdCents: $0, in: currency) } ?? L("price_no_retail"))
                    .font(.subheadline.weight(.bold))
            }
            if let note {
                Text(note).font(.footnote).italic().foregroundStyle(Bw.textMuted2).padding(.bottom, 8)
            }
            Divider()
            DetailRow(label: L("current_value")) {
                ValueLine(label: "", value: currentValue, isLoading: valueLoading, font: .subheadline)
            }
            if let owned {
                Divider()
                DetailRow(label: L("detail_my_collection")) {
                    Text(verbatim: "\(L("detail_total_paid")) \(Money.formatIn(owned.totalPaid(in: currency), currency)) · ×\(owned.totalQty)")
                        .font(.subheadline.weight(.medium))
                }
            }
            if currency == .vnd {
                Text(L("settings_currency_vnd_note")).font(.caption2).foregroundStyle(Bw.textFaint).padding(.top, 8)
            }
        }
        .bwCard(padding: 16)
    }

    private var minifigGrid: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionHeader(title: L("detail_minifigs_in_set"))
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible())], spacing: 10) {
                ForEach(minifigs) { fig in
                    Button { router.open(.minifig(fig.figNum)) } label: {
                        VStack(spacing: 6) {
                            RemoteImage([fig.imageUrl], maxPointSize: 120).frame(height: 110)
                            Text(fig.name).font(.caption.weight(.semibold)).foregroundStyle(Bw.text)
                                .multilineTextAlignment(.center).lineLimit(2)
                            Text(fig.figNum).font(.caption2).foregroundStyle(Bw.textMuted)
                        }
                        .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.plain)
                    .bwCard(padding: 10)
                }
            }
        }
    }

    private func link(_ text: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(text.isEmpty ? "—" : text).font(.subheadline.weight(.semibold)).foregroundStyle(Bw.link).multilineTextAlignment(.trailing)
        }
        .buttonStyle(.plain)
    }

    // MARK: Loading

    /// Resolves the hero once per open, then the dependent sections. `.task(id:)` cancels this when
    /// the page goes away, which is the "ignore stale results" guard.
    private func load() async {
        phase = .loading
        do {
            guard let loaded = try await CatalogRepository.shared.fetchSet(catalogKey) else {
                set = nil; phase = .loaded
                return
            }
            set = loaded
            phase = .loaded
            async let figs = loaded.setId.asyncMap { (try? await CatalogRepository.shared.fetchMinifigs(forSet: $0)) ?? [] } ?? []
            async let themeSets = (try? await CatalogRepository.shared.recentSets(inTheme: loaded.theme)) ?? []
            await loadValue(loaded)
            minifigs = await figs
            // Recommendations: 3 RANDOM same-theme sets the user neither owns nor wishlists, picked
            // ONCE per open so the cards don't reshuffle as the user adds/wishlists.
            related = Array(
                (await themeSets)
                    .filter { $0.id != loaded.id && !ownership.owned.contains($0.setNumber) && !ownership.wishlisted.contains($0.setNumber) }
                    .shuffled().prefix(3)
            )
        } catch is CancellationError {
        } catch {
            phase = .failed
        }
    }

    private func loadValue(_ set: CatalogSet) async {
        guard let setId = set.setId else { currentValue = CurrentValue.none; valueLoading = false; return }
        valueLoading = currentValue == nil
        let tier = ValueAggregator.tier(for: set.status, retiredYear: set.retiredYear, retiredMonth: set.retiredMonth)
        currentValue = await values.fetch(forSet: setId, retailUsdCents: set.retailPrice, tier: tier)
        valueLoading = false
    }

    private func refreshValueSoon() async {
        guard let set else { return }
        try? await Task.sleep(for: .seconds(2.5))
        await loadValue(set)
    }
}

private struct Hero: View {
    let set: CatalogSet
    @Binding var heroLoaded: Bool

    @Environment(AuthService.self) private var auth
    @Environment(OwnershipIndex.self) private var ownership
    @Environment(ItemSheetCoordinator.self) private var sheets

    var body: some View {
        VStack(spacing: 14) {
            Button {
                // Inert while only the "No image" placeholder is showing.
                if heroLoaded { sheets.showGallery(set.galleryUrls) }
            } label: {
                RemoteImage([set.imageUrl, set.boxImageUrl], maxPointSize: 360) { heroLoaded = $0 }
                    .frame(maxWidth: .infinity).frame(height: 240)
                    .background(Color.white, in: RoundedRectangle(cornerRadius: Bw.cardRadius, style: .continuous))
                    .clipShape(RoundedRectangle(cornerRadius: Bw.cardRadius, style: .continuous))
            }
            .buttonStyle(.plain)

            Text(set.name).font(.title3.weight(.bold)).multilineTextAlignment(.center)

            HStack(spacing: 10) {
                if ownership.isOwnedOrSold(set.setNumber) {
                    Button { sheets.details(set, tab: ownership.owned.contains(set.setNumber) ? .collection : .sales) } label: {
                        Label(L("action_see_detail"), systemImage: "checkmark")
                    }
                    .buttonStyle(.bwSecondary)
                } else {
                    Button { sheets.add(set, auth: auth) } label: { Label(L("action_add"), systemImage: "plus") }
                        .buttonStyle(.bwPrimary)
                    WishlistHeroButton(item: set, isWishlisted: ownership.wishlisted.contains(set.setNumber))
                }
            }
        }
        .bwCard(padding: 16)
    }
}

/// Full-width variant of the wishlist toggle for detail heroes.
struct WishlistHeroButton: View {
    let item: CatalogSet
    let isWishlisted: Bool

    @Environment(AuthService.self) private var auth
    @Environment(AppRouter.self) private var router
    @Environment(CollectionService.self) private var collection

    var body: some View {
        Button {
            guard auth.isSignedIn else { auth.requestSignIn(); return }
            collection.toggleWishlist(item, isWishlisted: isWishlisted)
            router.showToast(L(isWishlisted ? "toast_removed_wishlist" : "toast_added_wishlist", item.name))
        } label: {
            Label(L(isWishlisted ? "action_wishlisted" : "action_wishlist"), systemImage: isWishlisted ? "heart.fill" : "heart")
        }
        .buttonStyle(BwSecondaryButtonStyle(tint: isWishlisted ? Color(hex: 0xC9506F) : Bw.text))
        .sensoryFeedback(.selection, trigger: isWishlisted)
    }
}

extension Optional {
    func asyncMap<T>(_ transform: (Wrapped) async -> T) async -> T? {
        guard let self else { return nil }
        return await transform(self)
    }
}
