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

    init(catalogKey: String) {
        self.catalogKey = catalogKey
        // Candidate owned copies; `ownedRows(of:)` narrows them to the loaded variant. A "sid:" key (an
        // owned row's exact variant) is queried by set_id; a number key by the bare number (everything
        // before a "-<variant>" suffix), which spans that number's variants until the set loads.
        if let sid = CatalogKey.setId(catalogKey) {
            let id: Int64? = sid
            _copyRows = Query(filter: #Predicate<CollectionCopy> { $0.setId == id && !$0.tombstoned })
        } else {
            let number = Self.bareNumber(catalogKey)
            _copyRows = Query(filter: #Predicate<CollectionCopy> { $0.setNumber == number && !$0.tombstoned })
        }
    }

    /// The bare set number of a key, or "" for a "sid:" key (unknown until the set loads).
    private static func bareNumber(_ key: String) -> String {
        if CatalogKey.setId(key) != nil { return "" }
        guard let dash = key.lastIndex(of: "-"), dash != key.startIndex, Int(key[key.index(after: dash)...]) != nil else { return key }
        return String(key[..<dash])
    }

    /// This exact variant's copies (plus any legacy set_id-less copies of its number — see `ItemKey`).
    private func ownedRows(of set: CatalogSet) -> [CollectionCopy] {
        let keys = set.ownershipKeys
        return copyRows.filter { keys.contains($0.variantKey) }
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
            Hero(set: set)
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
        let rows = ownedRows(of: set)
        let owned = rows.isEmpty ? nil : DisplayBuilder.collectionItem(rows)
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
                // Notes can carry <a>/<br> markup; render links and breaks instead of the raw tags.
                Text(NoteMarkup.attributed(note)).font(.footnote).italic().foregroundStyle(Bw.textMuted2)
                    .tint(Bw.link).padding(.bottom, 8)
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
        // Re-read when the shared value cache refreshes.
        let _ = values.revision
        return VStack(alignment: .leading, spacing: 10) {
            SectionHeader(title: L("detail_minifigs_in_set"))
            // A `Grid`, not a lazy one: both cards of a row take the taller one's height, so their value
            // lines line up when one name wraps and the other doesn't.
            Grid(horizontalSpacing: 10, verticalSpacing: 10) {
                ForEach(Array(minifigs.chunked(2).enumerated()), id: \.offset) { _, pair in
                    GridRow {
                        ForEach(pair) { fig in
                            MinifigGridCard(fig: fig, value: values.value(forFig: fig.figNum)) { router.open(.minifig(fig.figNum)) }
                        }
                        // A lone card keeps its half width.
                        if pair.count == 1 { Color.clear.gridCellUnsizedAxes(.vertical) }
                    }
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
                    .filter { $0.id != loaded.id && !ownership.isOwned($0) && !ownership.isWishlisted($0) }
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

    @Environment(AuthService.self) private var auth
    @Environment(OwnershipIndex.self) private var ownership
    @Environment(ItemSheetCoordinator.self) private var sheets

    var body: some View {
        VStack(spacing: 14) {
            // Swipe (or tap a thumbnail) between the render and the box shot; a tap opens the full-screen
            // gallery at the image showing. Inert while only the "No image" tile is up.
            HeroImageGallery(urls: set.heroUrls) { loaded, index in
                sheets.showGallery(loaded, startingAt: loaded[index])
            }

            Text(set.name).font(.title3.weight(.bold)).multilineTextAlignment(.center)

            HStack(spacing: 10) {
                if ownership.isOwnedOrSold(set) {
                    Button { sheets.details(set, tab: ownership.isOwned(set) ? .collection : .sales) } label: {
                        Label(L("action_see_detail"), systemImage: "checkmark")
                    }
                    .buttonStyle(.bwSecondary)
                } else {
                    Button { sheets.add(set, auth: auth) } label: { Label(L("action_add"), systemImage: "plus") }
                        .buttonStyle(.bwPrimary)
                    WishlistHeroButton(item: set, isWishlisted: ownership.isWishlisted(set))
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

/// One fig in a set's "Minifigs in this set" grid — Android's `MinifigGridCard`: number chip, name,
/// image, then a badge saying whether the fig is **Exclusive** to this set or how many sets it appears
/// in, and its community value at the bottom. (Internal so it can be rendered on its own.)
struct MinifigGridCard: View {
    let fig: Minifig
    let value: CurrentValue?
    let onOpen: () -> Void

    var body: some View {
        VStack(spacing: 8) {
            Button(action: onOpen) {
                VStack(spacing: 8) {
                    Text(fig.figNum).font(.caption2.weight(.bold)).foregroundStyle(Bw.textSecondary).lineLimit(1)
                        .padding(.horizontal, 8).padding(.vertical, 3)
                        .background(Bw.track, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                    Text(fig.name).font(.subheadline.weight(.bold)).foregroundStyle(Bw.text)
                        .multilineTextAlignment(.center).lineLimit(2)
                        // Its full two lines: in a Grid row the card is first measured as short as it
                        // can be, which squeezed a long name onto one truncated line.
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity)
                    ItemThumb(urls: [fig.imageUrl], size: 96)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            HStack {
                if fig.setCount <= 1 {
                    StatusBadge(status: .exclusive)
                } else {
                    // A neutral pill in the Exclusive badge's slot and shape.
                    Text(L(fig.setCount == 1 ? "search_minifig_sets_one" : "search_minifig_sets_other", fig.setCount))
                        .font(.caption2.weight(.bold)).foregroundStyle(Bw.textSecondary).lineLimit(1)
                        .padding(.horizontal, 9).padding(.vertical, 3)
                        .background(Bw.track, in: Capsule())
                }
                Spacer(minLength: 0)
            }
            // Pushes the value line to the bottom of an equal-height card.
            Spacer(minLength: 0)
            ValueLine(label: L("price_value"), value: value)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .bwCard()
        .contentShape(RoundedRectangle(cornerRadius: Bw.cardRadius, style: .continuous))
        .onTapGesture(perform: onOpen)
    }
}
