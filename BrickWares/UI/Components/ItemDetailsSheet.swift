import SwiftData
import SwiftUI

/// Opens the unified See-Details sheet for one item.
struct ItemDetailsRequest: Identifiable {
    enum Tab: Hashable { case collection, sales }

    let id = UUID()
    /// Catalog identity used for "Add" from inside the sheet.
    var item: CatalogSet
    var initialTab: Tab = .collection
}

/// The See-Details sheet: a Collection ⇄ Sales toggle over one item's owned copies and its sales.
/// Reads the rows live, so it stays open across edits/deletes and closes itself only once both the
/// copies and the sales are gone.
struct ItemDetailsSheet: View {
    let request: ItemDetailsRequest

    @Environment(\.dismiss) private var dismiss
    @Environment(AppSettings.self) private var settings
    @Environment(AppRouter.self) private var router
    @Environment(CollectionService.self) private var collection
    @Environment(CatalogOverlay.self) private var overlay
    @Environment(ValueService.self) private var values

    @Query private var copyRows: [CollectionCopy]
    @Query private var saleRows: [Sale]

    @State private var tab: ItemDetailsRequest.Tab
    @State private var expandedNotes = Set<String>()
    @State private var addRequest: AddSheetRequest?
    @State private var sellTarget: OwnedCopy?

    init(request: ItemDetailsRequest) {
        self.request = request
        _tab = State(initialValue: request.initialTab)
        let number = request.item.setNumber
        _copyRows = Query(filter: #Predicate<CollectionCopy> { $0.setNumber == number && !$0.tombstoned },
                          sort: \CollectionCopy.updatedAt)
        _saleRows = Query(filter: #Predicate<Sale> { $0.setNumber == number && !$0.tombstoned },
                          sort: \Sale.updatedAt)
    }

    private var currency: AppCurrency { settings.currency }
    private var isFig: Bool { request.item.itemType == .minifig }

    private var ownedItem: CollectionItem? {
        let _ = (overlay.revision, values.revision)
        return copyRows.isEmpty ? nil : DisplayBuilder.collectionItem(copyRows)
    }

    private var sold: [SoldItem] {
        let _ = (overlay.revision, values.revision)
        return DisplayBuilder.sold(saleRows)
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Picker("", selection: $tab) {
                        Text(L("sheet_mode_collection")).tag(ItemDetailsRequest.Tab.collection)
                        Text(L("sheet_mode_sales")).tag(ItemDetailsRequest.Tab.sales)
                    }
                    .pickerStyle(.segmented)
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets())
                }

                switch tab {
                case .collection: collectionBody
                case .sales: salesBody
                }
            }
            .navigationTitle("\(request.item.setNumber) \(request.item.name)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button(L("action_close")) { dismiss() } }
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        addRequest = .add(request.item, salesMode: tab == .sales, allowSalesMode: false)
                    } label: { Image(systemName: "plus") }
                    .accessibilityLabel(tab == .sales ? L("sheet_add_sale") : L("sheet_add_item"))
                }
            }
        }
        .presentationDetents([.medium, .large])
        .sheet(item: $addRequest) { AddToCollectionSheet(request: $0) }
        .sheet(item: $sellTarget) { copy in
            if let ownedItem {
                SellCopySheet(item: ownedItem, copy: copy) { router.showToast(L("toast_sold", request.item.name)) }
            }
        }
        .onChange(of: copyRows.isEmpty && saleRows.isEmpty) { _, empty in if empty { dismiss() } }
    }

    // MARK: Collection tab

    @ViewBuilder private var collectionBody: some View {
        if let item = ownedItem {
            Section {
                ForEach(item.copies) { copy in copyRow(copy) }
            } footer: {
                HStack {
                    Text(verbatim: "\(L("sd_qty")) \(item.totalQty)")
                    Spacer()
                    Text(verbatim: "\(L("sd_avg")) \(Money.formatIn(item.avgPaid(in: currency), currency))")
                    Spacer()
                    Text(verbatim: "\(L("price_paid")) \(Money.formatIn(item.totalPaid(in: currency), currency))")
                }
                .font(.footnote.weight(.semibold))
                .foregroundStyle(Bw.textSecondary)
                .padding(.top, 4)
            }
        } else {
            emptyRow
        }
    }

    private func copyRow(_ copy: OwnedCopy) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(conditionLabel(copy.condition)).font(.subheadline.weight(.semibold))
                    Text(verbatim: "\(copy.dateAdded.isEmpty ? "—" : copy.dateAdded) · ×\(copy.qty)")
                        .font(.caption).foregroundStyle(Bw.textMuted)
                }
                Spacer()
                Text(Money.format(copy.pricePaid, from: copy.currency, to: currency))
                    .font(.subheadline.weight(.bold))
            }
            if let note = copy.note, !note.isEmpty {
                Text(note).font(.caption).foregroundStyle(Bw.textSecondary)
                    .lineLimit(expandedNotes.contains(copy.id) ? nil : 1)
                    .onTapGesture { expandedNotes.formSymmetricDifference([copy.id]) }
                    .accessibilityHint(L("sd_toggle_note_cd"))
            }
        }
        .padding(.vertical, 2)
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            Button(role: .destructive) { collection.removeCopy(id: copy.id) } label: {
                Label(L("action_delete"), systemImage: "trash")
            }
            // Minifigs aren't sold through the per-copy flow (matches Android's allowSell = false).
            if !isFig {
                Button { sellTarget = copy } label: { Label(L("action_sell"), systemImage: "dollarsign.circle") }
                    .tint(Bw.success)
            }
        }
        .swipeActions(edge: .leading) {
            Button { addRequest = AddSheetRequest(item: request.item, mode: .editCopy(copy)) } label: {
                Label(L("action_edit"), systemImage: "pencil")
            }
            .tint(Bw.link)
        }
        .contextMenu {
            Button { addRequest = AddSheetRequest(item: request.item, mode: .editCopy(copy)) } label: {
                Label(L("sd_edit_copy_cd"), systemImage: "pencil")
            }
            if !isFig {
                Button { sellTarget = copy } label: { Label(L("sd_sell_copy_cd"), systemImage: "dollarsign.circle") }
            }
            Button(role: .destructive) { collection.removeCopy(id: copy.id) } label: {
                Label(L("sd_delete_copy_cd"), systemImage: "trash")
            }
        }
    }

    // MARK: Sales tab

    @ViewBuilder private var salesBody: some View {
        if sold.isEmpty {
            emptyRow
        } else {
            Section {
                ForEach(sold) { sale in saleRow(sale) }
            } footer: {
                let profit = sold.reduce(Int64(0)) {
                    $0 + CurrencyConverter.shared.convert($1.profit, from: $1.currency, to: currency)
                }
                HStack {
                    Text(L("sales_profit_label"))
                    Spacer()
                    Text(signed(profit)).foregroundStyle(profit >= 0 ? Bw.success : Bw.error)
                }
                .font(.footnote.weight(.bold))
                .padding(.top, 4)
            }
        }
    }

    private func saleRow(_ sale: SoldItem) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(conditionLabel(sale.condition)).font(.subheadline.weight(.semibold))
                    Text(verbatim: "\(sale.soldOn ?? "—") · ×\(sale.quantity)").font(.caption).foregroundStyle(Bw.textMuted)
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 2) {
                    PriceLine(label: L("price_paid"), value: Money.format(sale.pricePaid, from: sale.currency, to: currency))
                    PriceLine(label: L("price_sale"), value: Money.format(sale.saleValue, from: sale.currency, to: currency), bold: true)
                }
            }
            if let note = sale.note, !note.isEmpty {
                Text(note).font(.caption).foregroundStyle(Bw.textSecondary)
                    .lineLimit(expandedNotes.contains(sale.id) ? nil : 1)
                    .onTapGesture { expandedNotes.formSymmetricDifference([sale.id]) }
            }
        }
        .padding(.vertical, 2)
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            Button(role: .destructive) {
                collection.removeSale(id: sale.id)
                router.showToast(L("toast_removed_sale", sale.name))
            } label: { Label(L("action_delete"), systemImage: "trash") }
        }
        .swipeActions(edge: .leading) {
            Button { addRequest = AddSheetRequest(item: request.item, mode: .editSale(sale)) } label: {
                Label(L("action_edit"), systemImage: "pencil")
            }
            .tint(Bw.link)
        }
        .contextMenu {
            Button { addRequest = AddSheetRequest(item: request.item, mode: .editSale(sale)) } label: {
                Label(L("sheet_edit_sale"), systemImage: "pencil")
            }
            Button(role: .destructive) {
                collection.removeSale(id: sale.id)
                router.showToast(L("toast_removed_sale", sale.name))
            } label: { Label(L("action_delete"), systemImage: "trash") }
        }
    }

    private var emptyRow: some View {
        Text(L("item_details_empty"))
            .font(.subheadline).foregroundStyle(Bw.textMuted)
            .frame(maxWidth: .infinity).padding(.vertical, 18)
            .listRowBackground(Color.clear)
    }

    private func conditionLabel(_ c: Condition) -> String {
        c == .used ? L("sheet_condition_used") : L("sheet_condition_new")
    }

    private func signed(_ amount: Int64) -> String {
        (amount > 0 ? "+" : "") + Money.formatIn(amount, currency)
    }
}

extension CatalogSet {
    /// Catalog identity rebuilt from an owned item (for Add / See Detail launched from a row card).
    init(_ item: CollectionItem, overlay: CatalogSet? = nil) {
        self = overlay ?? CatalogSet(
            setNumber: item.setNumber, name: item.name, itemType: item.itemType, theme: item.theme,
            releaseYear: item.releaseYear, releaseMonth: item.releaseMonth, pieces: item.pieces,
            minifigs: item.minifigs, retailPrice: item.retailPrice > 0 ? item.retailPrice : nil,
            status: item.status, imageUrl: item.imageUrl, boxImageUrl: item.boxImageUrl,
            thumbnailUrl: item.imageUrl, setId: item.setId
        )
        if item.itemType == .minifig { itemType = .minifig }
    }

    init(_ sale: SoldItem) {
        self.init(
            setNumber: sale.setNumber, name: sale.name, itemType: sale.itemType, theme: sale.theme,
            releaseYear: sale.releaseYear, releaseMonth: sale.releaseMonth, pieces: sale.pieces,
            minifigs: sale.minifigs, retailPrice: sale.retailPrice > 0 ? sale.retailPrice : nil,
            status: sale.status, imageUrl: sale.imageUrl, boxImageUrl: sale.boxImageUrl, thumbnailUrl: sale.imageUrl
        )
    }

    init(_ wish: WishlistEntry) {
        self.init(
            setNumber: wish.setNumber, name: wish.name, itemType: wish.itemType, theme: wish.theme,
            releaseYear: wish.releaseYear, releaseMonth: wish.releaseMonth, pieces: wish.pieces,
            minifigs: wish.minifigs, retailPrice: wish.retailPrice > 0 ? wish.retailPrice : nil,
            status: wish.status, imageUrl: wish.imageUrl, boxImageUrl: wish.boxImageUrl, thumbnailUrl: wish.imageUrl
        )
    }
}

/// Full-screen swipeable gallery. Candidates that fail to load are dropped.
struct ImageGallery: View {
    let urls: [String]
    @Environment(\.dismiss) private var dismiss
    @State private var failed = Set<String>()
    @State private var selection: String?

    private var visible: [String] { urls.filter { !failed.contains($0) } }

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Color.black.ignoresSafeArea()
            TabView(selection: $selection) {
                ForEach(visible, id: \.self) { url in
                    RemoteImage([url], maxPointSize: 900) { ok in if !ok { failed.insert(url) } }
                        .padding(12)
                        .tag(Optional(url))
                }
            }
            .tabViewStyle(.page(indexDisplayMode: visible.count > 1 ? .always : .never))

            Button { dismiss() } label: {
                Image(systemName: "xmark").font(.headline).foregroundStyle(.white)
                    .padding(11).background(.white.opacity(0.18), in: Circle())
            }
            .padding(16)
            .accessibilityLabel(L("action_close"))
        }
        .onChange(of: visible.isEmpty) { _, empty in if empty { dismiss() } }
    }
}

struct GalleryRequest: Identifiable {
    let id = UUID()
    var urls: [String]
}
