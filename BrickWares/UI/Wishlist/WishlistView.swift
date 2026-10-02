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
    /// The row awaiting a remove confirmation — a row id, resolved from the live list, so the alert
    /// closes itself if the row goes away meanwhile (a sync, or the item being added to the collection).
    @State private var pendingRemovalId: String?

    private var entries: [WishlistEntry] {
        let _ = (overlay.revision, values.revision, settings.ratesRevision)
        return auth.isSignedIn ? DisplayBuilder.wishlist(rows) : []
    }

    var body: some View {
        let entries = entries
        List {
            Group {
                BannerImage(name: "wishlist_banner", title: L("wishlist_title"))
                StatCardRow(entries: [
                    StatEntry(icon: "ic_bw_set", value: Money.count(entries.filter { $0.itemType == .set }.count), label: L("stat_sets")),
                    StatEntry(icon: "ic_bw_minifig", value: Money.count(entries.filter { $0.itemType == .minifig }.count), label: L("stat_minifigs")),
                    StatEntry(icon: "ic_bw_pieces", value: Money.count(entries.reduce(0) { $0 + $1.pieces }), label: L("stat_pieces")),
                ])
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
                            WishlistCard(entry: entry) { pendingRemovalId = entry.rowId }
                                // Both removal paths (this swipe and the card's heart) confirm first, like
                                // Collection and Sales (Android f1a1e0c).
                                .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                                    Button(role: .destructive) { pendingRemovalId = entry.rowId } label: {
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
        .contentMargins(.bottom, FloatingActionButton.listClearance, for: .scrollContent)
        .overlay(alignment: .bottomTrailing) {
            // Sends the user to Search to find sets to wishlist; needs the network and an account.
            if auth.isSignedIn, connectivity.isOnline {
                FloatingActionButton(
                    systemImage: "magnifyingglass", label: L("wishlist_search_fab_cd"),
                    // Pulses while the list is empty, to prompt the first search.
                    pulsing: !entries.contains { filter.matches($0.itemType) }
                ) { router.go(to: .search) }
            }
        }
        .bwScreen()
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
        .itemSheets()
        // A centred alert, like Android's dialog (a `confirmationDialog` is anchored to the view it hangs
        // on and, on iOS 26, popped up at the top of the list).
        .alert(
            L("wishlist_remove_title"),
            isPresented: Binding(get: { pendingRemoval(in: entries) != nil }, set: { if !$0 { pendingRemovalId = nil } }),
            presenting: pendingRemoval(in: entries)
        ) { entry in
            Button(L("action_remove"), role: .destructive) { remove(entry) }
            Button(L("action_cancel"), role: .cancel) {}
        } message: { entry in
            Text(L("wishlist_remove_confirm", entry.name))
        }
    }

    private func pendingRemoval(in entries: [WishlistEntry]) -> WishlistEntry? {
        pendingRemovalId.flatMap { id in entries.first { $0.rowId == id } }
    }

    private func remove(_ entry: WishlistEntry) {
        pendingRemovalId = nil
        collection.removeFromWishlist(setNumber: entry.setNumber, setId: entry.setId)
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
    /// Asks to remove this entry (the screen confirms first).
    let onRemove: () -> Void

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
                Button { router.open(entry.figNum != nil ? .minifig(entry.setNumber) : .set(CatalogKey.forRow(setId: entry.setId, setNumber: entry.setNumber))) } label: {
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
                .buttonStyle(.bwPrimaryColumn)
                // Same look as the shared heart, but in this tab removing asks first.
                Button(action: onRemove) { Label(L("action_wishlisted"), systemImage: "heart.fill") }
                    .buttonStyle(BwSecondaryButtonStyle(size: .column, tint: Color(hex: 0xC9506F)))
            }
            .priceColumn()
        }
        .bwCard()
    }
}
