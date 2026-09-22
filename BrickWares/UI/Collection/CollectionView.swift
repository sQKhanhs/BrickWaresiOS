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
    @State private var pendingDelete: PendingDelete?

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
        List {
            Group {
                BannerImage(name: mode == .collection ? "collection_banner" : "sales_banner")
                if mode == .collection {
                    collectionSections(items)
                } else {
                    salesSections(sold)
                }
            }
            .listRowSeparator(.hidden)
            .listRowBackground(Color.clear)
            .listRowInsets(EdgeInsets(top: 6, leading: Bw.gutter, bottom: 6, trailing: Bw.gutter))
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .bwScreen()
        .navigationTitle(mode == .collection ? L("collection_title") : L("sales_title"))
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Picker("", selection: $mode.animation(.snappy)) {
                    Text(L("sheet_mode_collection")).tag(Mode.collection)
                    Text(L("sheet_mode_sales")).tag(Mode.sales)
                }
                .pickerStyle(.segmented)
                .frame(width: 190)
                .accessibilityLabel(L("collection_toggle_sales_cd"))
            }
            // Adding needs the catalog (network) and an account.
            if auth.isSignedIn, connectivity.isOnline {
                ToolbarItem(placement: .primaryAction) { AddButton(salesMode: mode == .sales) }
            }
        }
        .itemSheets()
        .confirmationDialog(
            L("collection_delete_title"), isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }),
            titleVisibility: .visible, presenting: pendingDelete
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

    @ViewBuilder private func collectionSections(_ items: [CollectionItem]) -> some View {
        let summary = CollectionStats.summary(of: items, display: settings.currency)
        HStack(spacing: 10) {
            StatTile(value: Money.count(summary.setCount), label: L("stat_sets"))
            StatTile(value: Money.count(summary.minifigCount), label: L("stat_minifigs"))
            StatTile(value: Money.count(summary.pieceCount), label: L("stat_pieces"))
        }
        if !auth.isSignedIn {
            SignInPromptCard(message: L("collection_signin_prompt"))
        } else {
            HStack {
                Picker("", selection: $filter) {
                    ForEach(ItemFilter.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
                OptionMenu(title: L("search_sort_label"), options: ItemSort.allCases, selection: $sort, label: \.label)
            }
            let visible = sorted(items.filter { filter.matches($0.itemType) })
            if visible.isEmpty {
                EmptyStateView(message: L("collection_empty"))
            } else {
                ForEach(visible) { item in
                    OwnedItemCard(item: item)
                        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                            Button(role: .destructive) { pendingDelete = .item(item) } label: {
                                Label(L("action_delete"), systemImage: "trash")
                            }
                        }
                }
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

    @ViewBuilder private func salesSections(_ sold: [SoldItem]) -> some View {
        let summary = CollectionStats.salesSummary(of: sold, display: settings.currency)
        SalesSummaryTiles(summary: summary, currency: settings.currency)
        if !auth.isSignedIn {
            SignInPromptCard(message: L("sales_signin_prompt"))
        } else if sold.isEmpty {
            EmptyStateView(message: L("sales_empty"))
        } else {
            HStack {
                Spacer()
                OptionMenu(title: L("search_sort_label"), options: ItemSort.allCases, selection: $salesSort, label: \.label)
            }
            ForEach(sortedSales(sold)) { sale in
                SoldItemCard(sale: sale)
                    .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                        Button(role: .destructive) { pendingDelete = .sale(sale) } label: {
                            Label(L("action_delete"), systemImage: "trash")
                        }
                    }
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
            collection.removeItem(setNumber: item.setNumber)
            router.showToast(L("toast_removed_collection", item.name))
        case .sale(let sale):
            collection.removeSale(id: sale.id)
            router.showToast(L("toast_removed_sale", sale.name))
        }
    }
}

/// The "+" in the nav bar: opens the Add sheet in set-number lookup mode.
private struct AddButton: View {
    let salesMode: Bool
    @Environment(ItemSheetCoordinator.self) private var sheets

    var body: some View {
        Button { sheets.addRequest = .add(nil, salesMode: salesMode) } label: { Image(systemName: "plus") }
            .accessibilityLabel(L("collection_add_fab_cd"))
    }
}

private struct SalesSummaryTiles: View {
    let summary: SalesSummary
    let currency: AppCurrency

    var body: some View {
        let color: Color = summary.totalProfit > 0 ? Bw.success : (summary.totalProfit < 0 ? Bw.error : Bw.textMuted)
        VStack(spacing: 10) {
            HStack(spacing: 10) {
                StatTile(value: Money.count(summary.totalSold), label: L("sales_total_sold"))
                StatTile(value: Money.formatIn(summary.totalSaleValue, currency), label: L("sales_sale_value"))
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

struct OwnedItemCard: View {
    let item: CollectionItem

    @Environment(AppSettings.self) private var settings
    @Environment(AppRouter.self) private var router
    @Environment(ItemSheetCoordinator.self) private var sheets

    private var isFig: Bool { item.itemType == .minifig }

    var body: some View {
        let currency = settings.currency
        HStack(alignment: .top, spacing: 12) {
            Button {
                sheets.showGallery(isFig ? [item.imageUrl].compactMap { $0 } : RowImages.gallery(imageUrl: item.imageUrl, boxImageUrl: item.boxImageUrl))
            } label: {
                ItemThumb(urls: isFig ? [item.imageUrl] : RowImages.card(imageUrl: item.imageUrl, boxImageUrl: item.boxImageUrl), size: 72)
            }
            .buttonStyle(.plain)

            VStack(alignment: .leading, spacing: 5) {
                if isFig {
                    Text(item.setNumber).font(.caption2).foregroundStyle(Bw.textMuted)
                    // A CMF is minifig-styled but lives in the set catalog — route it to Set detail;
                    // only a real in-set fig (figNum set) opens Minifig detail.
                    titleButton(item.name) { router.open(item.figNum != nil ? .minifig(item.setNumber) : .set(item.setNumber)) }
                    if item.minifigSetCount > 0 { MetaLine(L("minifig_in_sets_label"), String(item.minifigSetCount)) }
                } else {
                    titleButton("\(item.setNumber) \(item.name)") { router.open(.set(item.setNumber)) }
                    MetaLine(L("meta_theme"), item.theme)
                    MetaLine(L("meta_release"), releaseLabel(year: item.releaseYear, month: item.releaseMonth))
                    MetaLine(L("meta_pieces_minifigs"), "\(Money.count(item.pieces)) / \(item.minifigs)")
                    StatusBadge(status: item.status)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            VStack(alignment: .trailing, spacing: 5) {
                // Minifigs never show retail and always show value; sets show value only when
                // retired / promo / magazine.
                if !isFig {
                    PriceLine(label: L("price_retail"), value: item.retailPrice > 0 ? Money.format(usdCents: item.retailPrice, in: currency) : L("price_no_retail"))
                }
                PriceLine(label: L("price_paid"), value: Money.formatIn(item.totalPaid(in: currency), currency), bold: true)
                if item.valueShown { ValueLine(label: L("price_value"), value: item.currentValueInfo) }
                if let growth = item.growthPercent { GrowthLabel(percent: growth, compact: true) }
                Button { sheets.details(CatalogSet(item)) } label: { Label(L("action_see_detail"), systemImage: "checkmark") }
                    .buttonStyle(.bwSecondaryCompact)
                    .padding(.top, 2)
            }
        }
        .bwCard()
    }

    private func titleButton(_ text: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(text).font(.subheadline.weight(.bold)).foregroundStyle(Bw.link).multilineTextAlignment(.leading).lineLimit(3)
        }
        .buttonStyle(.plain)
    }
}

struct SoldItemCard: View {
    let sale: SoldItem

    @Environment(AppSettings.self) private var settings
    @Environment(AppRouter.self) private var router
    @Environment(ItemSheetCoordinator.self) private var sheets

    private var isFig: Bool { sale.itemType == .minifig }

    var body: some View {
        let currency = settings.currency
        let profit = CurrencyConverter.shared.convert(sale.profit, from: sale.currency, to: currency)
        HStack(alignment: .top, spacing: 12) {
            ItemThumb(urls: isFig ? [sale.imageUrl] : RowImages.card(imageUrl: sale.imageUrl, boxImageUrl: sale.boxImageUrl), size: 72)

            VStack(alignment: .leading, spacing: 5) {
                Button { router.open(sale.figNum != nil ? .minifig(sale.setNumber) : .set(sale.setNumber)) } label: {
                    Text(isFig ? sale.name : "\(sale.setNumber) \(sale.name)")
                        .font(.subheadline.weight(.bold)).foregroundStyle(Bw.link).multilineTextAlignment(.leading).lineLimit(3)
                }
                .buttonStyle(.plain)
                MetaLine(L("meta_theme"), sale.theme)
                if !isFig { MetaLine(L("meta_release"), releaseLabel(year: sale.releaseYear, month: sale.releaseMonth)) }
                MetaLine(L("sd_qty"), "×\(sale.quantity)")
                if let soldOn = sale.soldOn { MetaLine(L("sd_date"), soldOn) }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            VStack(alignment: .trailing, spacing: 5) {
                if !isFig, sale.retailPrice > 0 {
                    PriceLine(label: L("price_retail"), value: Money.format(usdCents: sale.retailPrice, in: currency))
                }
                PriceLine(label: L("price_paid"), value: Money.format(sale.pricePaid, from: sale.currency, to: currency))
                PriceLine(label: L("price_sale"), value: Money.format(sale.saleValue, from: sale.currency, to: currency), bold: true)
                PriceLine(
                    label: L("sales_profit_label"), value: (profit > 0 ? "+" : "") + Money.formatIn(profit, currency),
                    valueColor: profit >= 0 ? Bw.success : Bw.error, bold: true
                )
                GrowthLabel(percent: sale.profitPercent, compact: true)
                Button { sheets.details(CatalogSet(sale), tab: .sales) } label: { Label(L("action_see_detail"), systemImage: "checkmark") }
                    .buttonStyle(.bwSecondaryCompact)
                    .padding(.top, 2)
            }
        }
        .bwCard()
    }
}
