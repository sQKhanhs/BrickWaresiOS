import SwiftData
import SwiftUI

struct WishlistView: View {
    @Environment(AuthService.self) private var auth
    @Environment(AppSettings.self) private var settings
    @Environment(AppRouter.self) private var router
    @Environment(Connectivity.self) private var connectivity
    @Environment(CatalogOverlay.self) private var overlay
    @Environment(ValueService.self) private var values
    @Environment(CollectionService.self) private var collection

    @Query(filter: #Predicate<WishlistItem> { !$0.tombstoned }) private var rows: [WishlistItem]

    @State private var filter: ItemFilter = .all
    @State private var sort: ItemSort = .dateAdded

    private var entries: [WishlistEntry] {
        let _ = (overlay.revision, values.revision, settings.ratesRevision)
        return auth.isSignedIn ? DisplayBuilder.wishlist(rows) : []
    }

    var body: some View {
        let entries = entries
        List {
            Group {
                BannerImage(name: "wishlist_banner")
                HStack(spacing: 10) {
                    StatTile(value: Money.count(entries.filter { $0.itemType == .set }.count), label: L("stat_sets"))
                    StatTile(value: Money.count(entries.filter { $0.itemType == .minifig }.count), label: L("stat_minifigs"))
                    StatTile(value: Money.count(entries.reduce(0) { $0 + $1.pieces }), label: L("stat_pieces"))
                }
                if !auth.isSignedIn {
                    SignInPromptCard(message: L("wishlist_signin_prompt"))
                } else {
                    HStack {
                        Picker("", selection: $filter) {
                            ForEach(ItemFilter.allCases) { Text($0.label).tag($0) }
                        }
                        .pickerStyle(.segmented)
                        OptionMenu(title: L("search_sort_label"), options: ItemSort.allCases, selection: $sort, label: \.label)
                    }
                    let visible = sorted(entries.filter { filter.matches($0.itemType) })
                    if visible.isEmpty {
                        EmptyStateView(
                            message: L("wishlist_empty"),
                            actionTitle: connectivity.isOnline ? L("nav_search") : nil
                        ) { router.go(to: .search) }
                    } else {
                        ForEach(visible) { entry in
                            WishlistCard(entry: entry)
                                // Removing a want is low-stakes (and re-addable), so no confirm — same as Android.
                                .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                                    Button(role: .destructive) { remove(entry) } label: {
                                        Label(L("wishlist_remove_cd"), systemImage: "heart.slash")
                                    }
                                }
                        }
                    }
                }
            }
            .listRowSeparator(.hidden)
            .listRowBackground(Color.clear)
            .listRowInsets(EdgeInsets(top: 6, leading: Bw.gutter, bottom: 6, trailing: Bw.gutter))
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .bwScreen()
        .navigationTitle(L("wishlist_title"))
        .toolbar {
            if auth.isSignedIn, connectivity.isOnline {
                ToolbarItem(placement: .primaryAction) {
                    Button { router.go(to: .search) } label: { Image(systemName: "magnifyingglass") }
                        .accessibilityLabel(L("wishlist_search_fab_cd"))
                }
            }
        }
        .itemSheets()
    }

    private func remove(_ entry: WishlistEntry) {
        collection.removeFromWishlist(setNumber: entry.setNumber)
        router.showToast(L("toast_removed_wishlist", entry.name))
    }

    private func sorted(_ entries: [WishlistEntry]) -> [WishlistEntry] {
        func key(_ e: WishlistEntry) -> Int { e.releaseYear * 100 + e.releaseMonth }
        return switch sort {
        case .name: entries.sorted { $0.name.lowercased() < $1.name.lowercased() }
        case .priceHigh: entries.sorted { $0.retailPrice > $1.retailPrice }
        case .priceLow: entries.sorted { $0.retailPrice < $1.retailPrice }
        case .dateAdded: entries.sorted { $0.addedAt > $1.addedAt }
        case .releaseNewest: entries.sorted { key($0) > key($1) }
        case .releaseOldest: entries.sorted { key($0) < key($1) }
        }
    }
}

private struct WishlistCard: View {
    let entry: WishlistEntry

    @Environment(AppSettings.self) private var settings
    @Environment(AppRouter.self) private var router
    @Environment(AuthService.self) private var auth
    @Environment(CollectionService.self) private var collection
    @Environment(ItemSheetCoordinator.self) private var sheets

    private var isFig: Bool { entry.itemType == .minifig }

    var body: some View {
        let currency = settings.currency
        HStack(alignment: .top, spacing: 12) {
            Button {
                sheets.showGallery(isFig ? [entry.imageUrl].compactMap { $0 } : RowImages.gallery(imageUrl: entry.imageUrl, boxImageUrl: entry.boxImageUrl))
            } label: {
                ItemThumb(urls: isFig ? [entry.imageUrl] : RowImages.card(imageUrl: entry.imageUrl, boxImageUrl: entry.boxImageUrl), size: 72)
            }
            .buttonStyle(.plain)

            VStack(alignment: .leading, spacing: 5) {
                Button { router.open(isFig ? .minifig(entry.setNumber) : .set(entry.setNumber)) } label: {
                    Text(verbatim: "\(entry.setNumber) \(entry.name)")
                        .font(.subheadline.weight(.bold)).foregroundStyle(Bw.link).multilineTextAlignment(.leading).lineLimit(3)
                }
                .buttonStyle(.plain)
                MetaLine(L("meta_theme"), entry.theme)
                if isFig {
                    MetaLine(L("filter_minifig"), entry.pieces > 0 ? L("meta_parts_count", entry.pieces) : "—")
                } else {
                    MetaLine(L("meta_release"), releaseLabel(year: entry.releaseYear, month: entry.releaseMonth))
                    MetaLine(L("meta_pieces_minifigs"), "\(Money.count(entry.pieces)) / \(entry.minifigs)")
                    StatusBadge(status: entry.status)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            VStack(alignment: .trailing, spacing: 6) {
                if !isFig {
                    PriceLine(label: L("price_retail"), value: entry.retailPrice > 0 ? Money.format(usdCents: entry.retailPrice, in: currency) : L("price_no_retail"), bold: true)
                }
                if entry.valueShown { ValueLine(label: L("price_value"), value: entry.currentValueInfo) }
                // "Add" moves the want into the collection (owning an item removes it from the wishlist).
                Button { sheets.add(CatalogSet(entry), allowSalesMode: false, auth: auth) } label: {
                    Label(L("action_add"), systemImage: "plus")
                }
                .buttonStyle(.bwPrimaryCompact)
                WishlistButton(item: CatalogSet(entry), isWishlisted: true)
            }
        }
        .bwCard()
    }
}
