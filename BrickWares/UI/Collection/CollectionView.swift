import SwiftData
import SwiftUI

/// Sort shared by Collection / Sales / Wishlist. Default everywhere is **date added**.
enum ItemSort: String, CaseIterable, Identifiable {
    case name, priceHigh, priceLow, dateAdded, releaseNewest, releaseOldest
    var id: String { rawValue }

    var label: String {
        switch self {
        case .name: L("sort_alphabetical")
        case .priceHigh: L("sort_price_high")
        case .priceLow: L("sort_price_low")
        case .dateAdded: L("sort_date_added")
        case .releaseNewest: L("sort_newest")
        case .releaseOldest: L("sort_oldest")
        }
    }
}

enum ItemFilter: String, CaseIterable, Identifiable {
    case all, set, minifig
    var id: String { rawValue }

    var label: String {
        switch self {
        case .all: L("filter_all")
        case .set: L("filter_set")
        case .minifig: L("filter_minifig")
        }
    }

    func matches(_ type: ItemType) -> Bool {
        switch self {
        case .all: true
        case .set: type == .set
        case .minifig: type == .minifig
        }
    }
}

/// `year*100 + month` — a month-unknown row (0) sorts first within its year.
private func releaseKey(_ year: Int, _ month: Int) -> Int { year * 100 + month }

struct CollectionView: View {
    enum Mode { case collection, sales }

    @Environment(AuthService.self) private var auth
    @Environment(AppSettings.self) private var settings
    @Environment(AppRouter.self) private var router
    @Environment(Connectivity.self) private var connectivity
    @Environment(CatalogOverlay.self) private var overlay
    @Environment(ValueService.self) private var values
    @Environment(CollectionService.self) private var collection

    @Query(filter: #Predicate<CollectionCopy> { !$0.tombstoned }) private var copyRows: [CollectionCopy]
    @Query(filter: #Predicate<Sale> { !$0.tombstoned }) private var saleRows: [Sale]

    @State private var mode: Mode = .collection
    @State private var filter: ItemFilter = .all
    @State private var sort: ItemSort = .dateAdded
    @State private var salesSort: ItemSort = .dateAdded
    /// Numbered pages, ten cards each (Android's `PAGE_SIZE`). One page per side; a filter or sort change
    /// goes back to the first, and a page left past the end by a delete is clamped when it is read.
    @State private var page = 1
    @State private var salesPage = 1
    @State private var pendingDelete: PendingDelete?

    private static let topID = "collection-top"

    private enum PendingDelete: Identifiable {
        case item(CollectionItem), sale(SoldItem)
        var id: String {
            switch self {
            case .item(let i): "i-\(i.id)"
            case .sale(let s): "s-\(s.id)"
            }
        }
    }

    private var items: [CollectionItem] {
        let _ = (overlay.revision, values.revision, settings.ratesRevision)
        return auth.isSignedIn ? DisplayBuilder.collectionItems(copyRows) : []
    }

    private var sold: [SoldItem] {
        let _ = (overlay.revision, values.revision, settings.ratesRevision)
        return auth.isSignedIn ? DisplayBuilder.sold(saleRows) : []
    }

    var body: some View {
        let items = items
        let sold = sold
        ScrollViewReader { proxy in
            List {
                Group {
                    // Banner and summary scroll away; the filter / sort row below them is a section
                    // header, which a plain list keeps pinned at the top (Android's `stickyHeader`).
                    Section {
                        BannerImage(name: mode == .collection ? "collection_banner" : "sales_banner",
                                    title: mode == .collection ? L("collection_title") : L("sales_title"))
                            .id(Self.topID)
                        if mode == .collection {
                            collectionSummary(items)
                        } else {
                            salesSummary(sold)
                        }
                    }
                    if mode == .collection {
                        collectionList(items)
                    } else {
                        salesList(sold)
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
            // A new page starts at the top, as does switching side.
            .onChange(of: page) { _, _ in proxy.scrollTo(Self.topID, anchor: .top) }
            .onChange(of: salesPage) { _, _ in proxy.scrollTo(Self.topID, anchor: .top) }
            .onChange(of: mode) { _, _ in proxy.scrollTo(Self.topID, anchor: .top) }
            .onChange(of: filter) { _, _ in page = 1 }
            .onChange(of: sort) { _, _ in page = 1 }
            .onChange(of: salesSort) { _, _ in salesPage = 1 }
        }
        .overlay(alignment: .bottomTrailing) {
            // Adding needs the catalog (network) and an account.
            if auth.isSignedIn, connectivity.isOnline {
                // Pulses while the collection list is empty, to prompt the first add (not in Sales mode).
                AddButton(
                    salesMode: mode == .sales,
                    pulsing: mode == .collection && !items.contains { filter.matches($0.itemType) }
                )
            }
        }
        // Collection ⇄ Sales, bottom-left like Android's swap button (always there, also signed out).
        .overlay(alignment: .bottomLeading) {
            SalesSwapButton(salesActive: mode == .sales) {
                withAnimation(.snappy) { mode = mode == .sales ? .collection : .sales }
            }
        }
        .bwScreen()
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
        .itemSheets()
        // A centred alert, like Android's dialog. A `confirmationDialog` is anchored to the view it hangs
        // on: on iOS 26 it grows out of that view as a popover, which put it at the top of the list,
        // nowhere near the swiped card.
        .alert(
            L("collection_delete_title"), isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }),
            presenting: pendingDelete
        ) { target in
            Button(L("action_delete"), role: .destructive) { confirmDelete(target) }
            Button(L("action_cancel"), role: .cancel) {}
        } message: { target in
            switch target {
            case .item(let i): Text(L("collection_delete_confirm", i.name))
            case .sale(let s): Text(L("sales_delete_confirm", s.name))
            }
        }
    }

    // MARK: Collection mode

    @ViewBuilder private func collectionSummary(_ items: [CollectionItem]) -> some View {
        let summary = CollectionStats.summary(of: items, display: settings.currency)
        StatCardRow(entries: [
            StatEntry(icon: "ic_bw_set", value: Money.count(summary.setCount), label: L("stat_sets")),
            StatEntry(icon: "ic_bw_minifig", value: Money.count(summary.minifigCount), label: L("stat_minifigs")),
            StatEntry(icon: "ic_bw_pieces", value: Money.count(summary.pieceCount), label: L("stat_pieces")),
        ])
        if !auth.isSignedIn {
            SignInPromptCard(message: L("collection_signin_prompt"))
        }
    }

    /// The cards, under the pinned filter + sort row.
    @ViewBuilder private func collectionList(_ items: [CollectionItem]) -> some View {
        if auth.isSignedIn {
            Section {
                let visible = sorted(items.filter { filter.matches($0.itemType) })
                if visible.isEmpty {
                    EmptyStateView(message: L("collection_empty"))
                } else {
                    ForEach(Pagination.items(visible, page: page)) { item in
                        OwnedItemCard(item: item)
                            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                                Button(role: .destructive) { pendingDelete = .item(item) } label: {
                                    Label(L("action_delete"), systemImage: "trash")
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

    private func sorted(_ items: [CollectionItem]) -> [CollectionItem] {
        switch sort {
        case .name: items.sorted { $0.name.lowercased() < $1.name.lowercased() }
        case .priceHigh: items.sorted { $0.totalPaid > $1.totalPaid }
        case .priceLow: items.sorted { $0.totalPaid < $1.totalPaid }
        // Lexicographic on ISO dates; blank dates sink to the bottom.
        case .dateAdded: items.sorted { newestDate($0) > newestDate($1) }
        case .releaseNewest: items.sorted { releaseKey($0.releaseYear, $0.releaseMonth) > releaseKey($1.releaseYear, $1.releaseMonth) }
        case .releaseOldest: items.sorted { releaseKey($0.releaseYear, $0.releaseMonth) < releaseKey($1.releaseYear, $1.releaseMonth) }
        }
    }

    private func newestDate(_ item: CollectionItem) -> String { item.copies.map(\.dateAdded).max() ?? "" }

    // MARK: Sales mode

    @ViewBuilder private func salesSummary(_ sold: [SoldItem]) -> some View {
        let summary = CollectionStats.salesSummary(of: sold, display: settings.currency)
        SalesSummaryTiles(summary: summary, currency: settings.currency)
        if !auth.isSignedIn {
            SignInPromptCard(message: L("sales_signin_prompt"))
        } else if sold.isEmpty {
            EmptyStateView(message: L("sales_empty"))
        }
    }

    /// The sold cards, under the pinned sort control (Sales has no All / Set / Minifig filter).
    @ViewBuilder private func salesList(_ sold: [SoldItem]) -> some View {
        if auth.isSignedIn, !sold.isEmpty {
            Section {
                ForEach(Pagination.items(sortedSales(sold), page: salesPage)) { sale in
                    SoldItemCard(sale: sale)
                        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                            Button(role: .destructive) { pendingDelete = .sale(sale) } label: {
                                Label(L("action_delete"), systemImage: "trash")
                            }
                        }
                }
                PaginationBar(
                    currentPage: Pagination.clamp(salesPage, total: sold.count),
                    totalPages: Pagination.pageCount(of: sold.count)
                ) { salesPage = $0 }
            } header: {
                HStack {
                    Spacer()
                    OptionMenu(title: L("search_sort_label"), options: ItemSort.allCases, selection: $salesSort, label: \.label)
                }
                .pinnedControls(inList: true)
            }
        }
    }

    private func sortedSales(_ sold: [SoldItem]) -> [SoldItem] {
        let fx = CurrencyConverter.shared
        switch salesSort {
        case .name: return sold.sorted { $0.name.lowercased() < $1.name.lowercased() }
        case .priceHigh: return sold.sorted { fx.usdCents(of: $0.saleValue, $0.currency) > fx.usdCents(of: $1.saleValue, $1.currency) }
        case .priceLow: return sold.sorted { fx.usdCents(of: $0.saleValue, $0.currency) < fx.usdCents(of: $1.saleValue, $1.currency) }
        case .dateAdded: return sold.sorted { ($0.soldOn ?? "") > ($1.soldOn ?? "") }
        case .releaseNewest: return sold.sorted { releaseKey($0.releaseYear, $0.releaseMonth) > releaseKey($1.releaseYear, $1.releaseMonth) }
        case .releaseOldest: return sold.sorted { releaseKey($0.releaseYear, $0.releaseMonth) < releaseKey($1.releaseYear, $1.releaseMonth) }
        }
    }

    private func confirmDelete(_ target: PendingDelete) {
        switch target {
        case .item(let item):
            collection.removeItem(setNumber: item.setNumber, setId: item.setId)
            router.showToast(L("toast_removed_collection", item.name))
        case .sale(let sale):
            collection.removeSale(id: sale.id)
            router.showToast(L("toast_removed_sale", sale.name))
        }
    }
}

/// The floating "+": opens the Add sheet in set-number lookup mode. Its own view because the sheet
/// coordinator is injected by `.itemSheets()`, below `CollectionView` itself.
private struct AddButton: View {
    let salesMode: Bool
    let pulsing: Bool
    @Environment(ItemSheetCoordinator.self) private var sheets

    var body: some View {
        FloatingActionButton(systemImage: "plus", label: L("collection_add_fab_cd"), pulsing: pulsing) {
            sheets.addRequest = .add(nil, salesMode: salesMode)
        }
    }
}

/// The Sales summary, laid out like Android's `SalesStatsRow` + `ProfitBar`: Total Sold in a round cream
/// badge, Sale Value in a shorter cream card centred against it, then the profit bar.
struct SalesSummaryTiles: View {
    let summary: SalesSummary
    let currency: AppCurrency

    private var cream: Color { Bw.yellow.opacity(0.16) }
    private var gold: Color { Bw.link2 }

    var body: some View {
        let color: Color = summary.totalProfit > 0 ? Bw.success : (summary.totalProfit < 0 ? Bw.error : Bw.textMuted)
        VStack(spacing: 12) {
            HStack(spacing: 12) {
                VStack(spacing: 0) {
                    Image("ic_bw_set").resizable().scaledToFit().frame(width: 22, height: 22).foregroundStyle(gold)
                    Text(L("sales_total_sold"))
                        .font(.system(size: 10, weight: .bold)).tracking(0.4).foregroundStyle(gold)
                        .lineLimit(1).minimumScaleFactor(0.7).padding(.top, 6)
                    Text(Money.count(summary.totalSold))
                        .font(.system(size: 22, weight: .black)).foregroundStyle(Bw.text)
                        .lineLimit(1).minimumScaleFactor(0.6).contentTransition(.numericText())
                        .padding(.top, 2)
                }
                .padding(.horizontal, 10)
                .frame(width: 112, height: 112)
                .background(cream, in: Circle())
                .accessibilityElement(children: .combine)

                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 7) {
                        Text(verbatim: "$").font(.system(size: 18, weight: .bold))
                        Text(L("sales_sale_value")).font(.system(size: 12, weight: .bold)).tracking(0.4).lineLimit(1)
                    }
                    .foregroundStyle(gold)
                    Text(Money.formatIn(summary.totalSaleValue, currency))
                        .font(.system(size: 22, weight: .black)).foregroundStyle(Bw.text)
                        .lineLimit(1).minimumScaleFactor(0.5).contentTransition(.numericText())
                }
                .padding(.horizontal, 18)
                .frame(maxWidth: .infinity, alignment: .leading)
                .frame(height: 88)
                .background(cream, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                .accessibilityElement(children: .combine)
            }
            HStack(spacing: 8) {
                // No arrow and no "+" at exactly zero.
                if summary.totalProfit != 0 {
                    Image(systemName: summary.totalProfit > 0 ? "chart.line.uptrend.xyaxis" : "chart.line.downtrend.xyaxis")
                }
                Text(L("sales_profit_prefix", signed(summary.totalProfit))).font(.subheadline.weight(.bold))
                Spacer()
                Text(signedPercent(summary.profitPercent))
                    .font(.caption.weight(.bold))
                    .padding(.horizontal, 9).padding(.vertical, 4)
                    .background(color.opacity(0.18), in: Capsule())
            }
            .foregroundStyle(color)
            .padding(.horizontal, 14).padding(.vertical, 11)
            .background(color.opacity(0.12), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
    }

    private func signed(_ amount: Int64) -> String { (amount > 0 ? "+" : "") + Money.formatIn(amount, currency) }

    private func signedPercent(_ p: Double) -> String {
        let r = (p * 10).rounded() / 10
        return (r > 0 ? "+" : "") + Money.oneDecimal(r) + "%"
    }
}

// MARK: - Cards

/// An owned item on the Collection tab — Android's `ItemCard`.
///
/// What it shows, by kind:
/// - **Set:** Theme / Release / Pieces-Minifigs / status on the left; Retail, Paid and growth on the
///   right. The community **Value** appears only for a retired, promo or magazine set — below a rule,
///   with its "!" explainer beside the status badge. A set still on sale is worth its retail price, so
///   no Value line.
/// - **Minifig:** number, name and "In N sets"; Paid, Value (always — a minifig has no retail) and growth.
struct OwnedItemCard: View {
    let item: CollectionItem

    @Environment(AppSettings.self) private var settings
    @Environment(AppRouter.self) private var router
    @Environment(ItemSheetCoordinator.self) private var sheets

    private var isFig: Bool { item.itemType == .minifig }
    private var showValue: Bool { item.status.showsCommunityValue }

    var body: some View {
        let currency = settings.currency
        HStack(alignment: .top, spacing: 10) {
            Button {
                sheets.showGallery(isFig ? [item.imageUrl].compactMap { $0 } : RowImages.gallery(imageUrl: item.imageUrl, boxImageUrl: item.boxImageUrl))
            } label: {
                ItemThumb(urls: isFig ? [item.imageUrl] : RowImages.card(imageUrl: item.imageUrl, boxImageUrl: item.boxImageUrl), size: 72)
            }
            .buttonStyle(.plain)
            .padding(.trailing, 2)

            VStack(alignment: .leading, spacing: 5) {
                if isFig {
                    Text(item.setNumber).font(.caption2).foregroundStyle(Bw.textMuted)
                    // A CMF is minifig-styled but lives in the set catalog — route it to Set detail;
                    // only a real in-set fig (figNum set) opens Minifig detail.
                    titleButton(item.name) { router.open(item.figNum != nil ? .minifig(item.setNumber) : .set(CatalogKey.forRow(setId: item.setId, setNumber: item.setNumber))) }
                    if item.minifigSetCount > 0 { MinifigSetsWithValueInfo(setCount: item.minifigSetCount, value: item.currentValueInfo) }
                } else {
                    titleButton("\(item.setNumber) \(item.name)") { router.open(.set(CatalogKey.forRow(setId: item.setId, setNumber: item.setNumber))) }
                    MetaLine(L("meta_theme"), item.theme)
                    MetaLine(L("meta_release"), releaseLabel(year: item.releaseYear, month: item.releaseMonth))
                    MetaLine(L("meta_pieces_minifigs"), "\(Money.count(item.pieces)) / \(item.minifigs)")
                    if showValue {
                        StatusBadgeWithValueInfo(status: item.status, value: item.currentValueInfo)
                    } else {
                        StatusBadge(status: item.status)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            VStack(alignment: .trailing, spacing: 5) {
                let paid = PriceLine(label: L("price_paid"), value: Money.formatIn(item.totalPaid(in: currency), currency))
                if isFig {
                    paid
                    // The "!" sits beside "In N sets" when that line shows; else it stays here.
                    ValueLine(label: L("price_value"), value: item.currentValueInfo, spread: true, showsInfo: item.minifigSetCount == 0)
                } else {
                    PriceLine(label: L("price_retail"), value: item.retailPrice > 0 ? Money.format(usdCents: item.retailPrice, in: currency) : L("price_no_retail"))
                    if showValue { Divider().overlay(Bw.borderSoft) }
                    paid
                    if showValue { ValueLine(label: L("price_value"), value: item.currentValueInfo, spread: true, showsInfo: false) }
                }
                if let growth = item.growthPercent { GrowthLabel(percent: growth, compact: true, pill: true) }
                Button { sheets.details(CatalogSet(item)) } label: { Label(L("action_see_detail"), systemImage: "checkmark") }
                    .buttonStyle(.bwTonalColumn)
                    .padding(.top, 2)
            }
            .priceColumn(minWidth: 130)
        }
        .bwCard()
    }

    private func titleButton(_ text: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(text).font(.subheadline.weight(.bold)).foregroundStyle(Bw.link).multilineTextAlignment(.leading).cardTitleLines()
        }
        .buttonStyle(.plain)
    }
}

/// A sale on the Collection tab's Sales side — Android's `SoldCard`: the catalog facts on the left (a
/// minifig shows just its number and name); on the right, a set's Retail — and its current Value when it
/// is retired, promo or magazine — above a rule, then the sale's own Paid, Sale, Profit and growth.
struct SoldItemCard: View {
    let sale: SoldItem

    @Environment(AppSettings.self) private var settings
    @Environment(AppRouter.self) private var router
    @Environment(ItemSheetCoordinator.self) private var sheets

    private var isFig: Bool { sale.itemType == .minifig }
    /// Current value only where it means something: retired / promo / magazine sets.
    private var showValue: Bool { !isFig && sale.status.showsCommunityValue }

    var body: some View {
        let currency = settings.currency
        let profit = CurrencyConverter.shared.convert(sale.profit, from: sale.currency, to: currency)
        HStack(alignment: .top, spacing: 10) {
            ItemThumb(urls: isFig ? [sale.imageUrl] : RowImages.card(imageUrl: sale.imageUrl, boxImageUrl: sale.boxImageUrl), size: 72)
                .padding(.trailing, 2)

            VStack(alignment: .leading, spacing: 5) {
                if isFig {
                    Text(sale.setNumber).font(.caption2).foregroundStyle(Bw.textMuted)
                    title(sale.name)
                } else {
                    title("\(sale.setNumber) \(sale.name)")
                    MetaLine(L("meta_theme"), sale.theme)
                    MetaLine(L("meta_release"), releaseLabel(year: sale.releaseYear, month: sale.releaseMonth))
                    MetaLine(L("meta_pieces_minifigs"), "\(Money.count(sale.pieces)) / \(sale.minifigs)")
                    if showValue {
                        StatusBadgeWithValueInfo(status: sale.status, value: sale.currentValueInfo)
                    } else {
                        StatusBadge(status: sale.status)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            VStack(alignment: .trailing, spacing: 5) {
                if !isFig {
                    PriceLine(label: L("price_retail"), value: sale.retailPrice > 0 ? Money.format(usdCents: sale.retailPrice, in: currency) : L("price_no_retail"))
                    if showValue { ValueLine(label: L("price_value"), value: sale.currentValueInfo, spread: true, showsInfo: false) }
                    Divider().overlay(Bw.borderSoft)
                }
                PriceLine(label: L("price_paid"), value: Money.format(sale.pricePaid, from: sale.currency, to: currency))
                PriceLine(label: L("price_sale"), value: Money.format(sale.saleValue, from: sale.currency, to: currency))
                PriceLine(
                    label: L("sales_profit_label"), value: (profit > 0 ? "+" : "") + Money.formatIn(profit, currency),
                    valueColor: profit >= 0 ? Bw.success : Bw.error
                )
                GrowthLabel(percent: sale.profitPercent, compact: true, pill: true)
                Button { sheets.details(CatalogSet(sale), tab: .sales) } label: { Label(L("action_see_detail"), systemImage: "checkmark") }
                    .buttonStyle(.bwTonalColumn)
                    .padding(.top, 2)
            }
            .priceColumn(minWidth: 130)
        }
        .bwCard()
    }

    private func title(_ text: String) -> some View {
        Button { router.open(sale.figNum != nil ? .minifig(sale.setNumber) : .set(CatalogKey.forRow(setId: sale.setId, setNumber: sale.setNumber))) } label: {
            Text(text).font(.subheadline.weight(.bold)).foregroundStyle(Bw.link).multilineTextAlignment(.leading).cardTitleLines()
        }
        .buttonStyle(.plain)
    }
}
