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
    /// Numbered pages, ten cards each; a filter or sort change goes back to the first.
    @State private var page = 1
    /// The row awaiting a remove confirmation — a row id, resolved from the live list, so the alert
    /// closes itself if the row goes away meanwhile (a sync, or the item being added to the collection).
    @State private var pendingRemovalId: String?

    private static let topID = "wishlist-top"

    private var entries: [WishlistEntry] {
        let _ = (overlay.revision, values.revision, settings.ratesRevision)
        return auth.isSignedIn ? DisplayBuilder.wishlist(rows) : []
    }

    var body: some View {
        let entries = entries
        ScrollViewReader { proxy in
            List {
                Group {
                    // Banner and counts scroll away; the filter / sort row below them is a section
                    // header, which a plain list keeps pinned at the top (Android's `stickyHeader`).
                    Section {
                        BannerImage(name: "wishlist_banner", title: L("wishlist_title"))
                            .id(Self.topID)
                        StatCardRow(entries: [
                            StatEntry(icon: "ic_bw_set", value: Money.count(entries.filter { $0.itemType == .set }.count), label: L("stat_sets")),
                            StatEntry(icon: "ic_bw_minifig", value: Money.count(entries.filter { $0.itemType == .minifig }.count), label: L("stat_minifigs")),
                            StatEntry(icon: "ic_bw_pieces", value: Money.count(entries.reduce(0) { $0 + $1.pieces }), label: L("stat_pieces")),
                        ])
                        if !auth.isSignedIn {
                            SignInPromptCard(message: L("wishlist_signin_prompt"))
                        }
                    }
                    if auth.isSignedIn {
                        Section {
                            let visible = sorted(entries.filter { filter.matches($0.itemType) })
                            if visible.isEmpty {
                                EmptyStateView(
                                    message: L("wishlist_empty"),
                                    actionTitle: connectivity.isOnline ? L("nav_search") : nil
                                ) { router.go(to: .search) }
                            } else {
                                ForEach(Pagination.items(visible, page: page)) { entry in
                                    WishlistCard(entry: entry) { pendingRemovalId = entry.rowId }
                                        // Both removal paths (this swipe and the card's heart) confirm first, like
                                        // Collection and Sales (Android f1a1e0c).
                                        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                                            Button(role: .destructive) { pendingRemovalId = entry.rowId } label: {
                                                Label(L("wishlist_remove_cd"), systemImage: "heart.slash")
                                            }
                                        }
                                }
                                PaginationBar(
                                    currentPage: Pagination.clamp(page, total: visible.count),
                                    totalPages: Pagination.pageCount(of: visible.count)
                                ) { page = $0 }
                            }
                        } header: {
                            HStack {
                                Picker("", selection: $filter) {
                                    ForEach(ItemFilter.allCases) { Text($0.label).tag($0) }
                                }
                                .pickerStyle(.segmented)
                                OptionMenu(title: L("search_sort_label"), options: ItemSort.allCases, selection: $sort, label: \.label)
                            }
                            .pinnedControls(inList: true)
                        }
                    }
                }
                .listRowSeparator(.hidden)
                .listSectionSeparator(.hidden)
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets(top: 6, leading: Bw.gutter, bottom: 6, trailing: Bw.gutter))
            }
            .listStyle(.plain)
            // Without this a plain list leaves a tall gap above the pinned header.
            .listSectionSpacing(0)
            .scrollContentBackground(.hidden)
            .opaqueTopBar()
            .contentMargins(.bottom, FloatingActionButton.listClearance, for: .scrollContent)
            .onChange(of: page) { _, _ in proxy.scrollTo(Self.topID, anchor: .top) }
            .onChange(of: filter) { _, _ in page = 1 }
            .onChange(of: sort) { _, _ in page = 1 }
        }
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

/// A wanted item — Android's `WishlistCard`. Unlike an owned card it ALWAYS shows the community Value
/// (whatever the status: it is what the item would cost now), with "----" until one exists and the "!"
/// explainer beside the status badge. (Internal so it can be rendered on its own.)
struct WishlistCard: View {
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
        HStack(alignment: .top, spacing: 10) {
            Button {
                sheets.showGallery(isFig ? [entry.imageUrl].compactMap { $0 } : RowImages.gallery(imageUrl: entry.imageUrl, boxImageUrl: entry.boxImageUrl))
            } label: {
                ItemThumb(urls: isFig ? [entry.imageUrl] : RowImages.card(imageUrl: entry.imageUrl, boxImageUrl: entry.boxImageUrl), size: 72)
            }
            .buttonStyle(.plain)
            .padding(.trailing, 2)

            VStack(alignment: .leading, spacing: 5) {
                Button { router.open(entry.figNum != nil ? .minifig(entry.setNumber) : .set(CatalogKey.forRow(setId: entry.setId, setNumber: entry.setNumber))) } label: {
                    Text(verbatim: "\(entry.setNumber) \(entry.name)")
                        .font(.subheadline.weight(.bold)).foregroundStyle(Bw.link).multilineTextAlignment(.leading).cardTitleLines()
                }
                .buttonStyle(.plain)
                MetaLine(L("meta_theme"), entry.theme)
                if isFig {
                    MetaLine(L("filter_minifig"), entry.pieces > 0 ? L("meta_parts_count", entry.pieces) : "—")
                } else {
                    MetaLine(L("meta_release"), releaseLabel(year: entry.releaseYear, month: entry.releaseMonth))
                    MetaLine(L("meta_pieces_minifigs"), "\(Money.count(entry.pieces)) / \(entry.minifigs)")
                    StatusBadgeWithValueInfo(status: entry.status, value: entry.currentValueInfo)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            VStack(alignment: .trailing, spacing: 5) {
                if !isFig {
                    PriceLine(label: L("price_retail"), value: entry.retailPrice > 0 ? Money.format(usdCents: entry.retailPrice, in: currency) : L("price_no_retail"))
                }
                // A minifig has no badge to carry the "!", so it stays on the value line.
                ValueLine(label: L("price_value"), value: entry.currentValueInfo, spread: true, showsInfo: isFig)
                // "Add" moves the want into the collection (owning an item removes it from the wishlist).
                Button { sheets.add(CatalogSet(entry), allowSalesMode: false, auth: auth) } label: { CardAddLabel() }
                    .buttonStyle(.bwPrimaryColumn)
                    .padding(.top, 2)
                // Same look as the shared heart, but in this tab removing asks first.
                Button(action: onRemove) { CardWishlistLabel(isWishlisted: true) }
                    .buttonStyle(.bwSecondaryColumn)
            }
            .priceColumn()
        }
        .bwCard()
    }
}
