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

/// The See-Details sheet: a Collection ⇄ Sales toggle over one item's owned copies and its sales, laid
/// out like Android's `ItemDetailsDialog` — a small table per side with the row actions (note, edit,
/// sell, delete) as VISIBLE buttons, a totals row, and an Add button at the bottom. The actions used to
/// be swipe and long-press only, which nobody would find. One deliberate difference: delete asks first.
///
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
    /// A delete awaiting confirmation. The bin sits right beside edit and sell, and a deleted copy or
    /// sale can't be brought back — so, unlike Android's dialog, this one asks first.
    @State private var pendingDelete: PendingDelete?

    private enum PendingDelete {
        case copy(OwnedCopy), sale(SoldItem)
    }

    init(request: ItemDetailsRequest) {
        self.request = request
        _tab = State(initialValue: request.initialTab)
        // This exact variant's rows (see `ItemKey`): a shared number's other variants are other items, so
        // the sheet must never list — or edit, sell, delete — a sibling's copies. Legacy set_id-less rows
        // of the number still match; they're what marks the item owned.
        let number = request.item.setNumber
        if let sid = request.item.setId {
            let id: Int64? = sid
            _copyRows = Query(filter: #Predicate<CollectionCopy> {
                !$0.tombstoned && ($0.setId == id || ($0.setId == nil && $0.setNumber == number))
            }, sort: \CollectionCopy.updatedAt)
            _saleRows = Query(filter: #Predicate<Sale> {
                !$0.tombstoned && ($0.setId == id || ($0.setId == nil && $0.setNumber == number))
            }, sort: \Sale.updatedAt)
        } else {
            _copyRows = Query(filter: #Predicate<CollectionCopy> { !$0.tombstoned && $0.setId == nil && $0.setNumber == number },
                              sort: \CollectionCopy.updatedAt)
            _saleRows = Query(filter: #Predicate<Sale> { !$0.tombstoned && $0.setId == nil && $0.setNumber == number },
                              sort: \Sale.updatedAt)
        }
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
            ScrollView {
                VStack(spacing: 14) {
                    Picker("", selection: $tab) {
                        Text(L("sheet_mode_collection")).tag(ItemDetailsRequest.Tab.collection)
                        Text(L("sheet_mode_sales")).tag(ItemDetailsRequest.Tab.sales)
                    }
                    .pickerStyle(.segmented)

                    switch tab {
                    case .collection:
                        if let item = ownedItem {
                            ItemCopiesTable(
                                item: item, currency: currency,
                                // Minifigs aren't sold through the per-copy flow (Android's allowSell = false).
                                allowSell: !isFig, expanded: $expandedNotes,
                                onEdit: { addRequest = AddSheetRequest(item: request.item, mode: .editCopy($0)) },
                                onSell: { sellTarget = $0 },
                                onDelete: { pendingDelete = .copy($0) }
                            )
                            .bwCard(padding: 12)
                        } else {
                            emptyBody
                        }
                    case .sales:
                        if sold.isEmpty {
                            emptyBody
                        } else {
                            ItemSalesTable(
                                sales: sold, currency: currency, expanded: $expandedNotes,
                                onEdit: { addRequest = AddSheetRequest(item: request.item, mode: .editSale($0)) },
                                onDelete: { pendingDelete = .sale($0) }
                            )
                            .bwCard(padding: 12)
                        }
                    }
                }
                .padding(Bw.gutter)
            }
            .bwScreen()
            .navigationTitle("\(request.item.setNumber) \(request.item.name)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button(L("action_close")) { dismiss() } }
            }
            // Add another copy / sale — pinned, so a long list never pushes it out of reach.
            .safeAreaInset(edge: .bottom) {
                Button(L("sheet_add_item")) {
                    addRequest = .add(request.item, salesMode: tab == .sales, allowSalesMode: false)
                }
                .buttonStyle(.bwPrimary)
                .padding(.horizontal, Bw.gutter).padding(.vertical, 10)
                .background(Bw.bg)
            }
        }
        .presentationDetents([.medium, .large])
        .sheet(item: $addRequest) { AddToCollectionSheet(request: $0) }
        .sheet(item: $sellTarget) { copy in
            if let ownedItem {
                SellCopySheet(item: ownedItem, copy: copy) { router.showToast(L("toast_sold", request.item.name)) }
            }
        }
        .alert(
            deleteTitle, isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }),
            presenting: pendingDelete
        ) { target in
            Button(L("action_delete"), role: .destructive) {
                switch target {
                case .copy(let copy): collection.removeCopy(id: copy.id)
                case .sale(let sale): collection.removeSale(id: sale.id)
                }
            }
            Button(L("action_cancel"), role: .cancel) {}
        } message: { target in
            switch target {
            case .copy: Text(L("sd_delete_copy_confirm", request.item.name))
            case .sale: Text(L("sales_delete_confirm", request.item.name))
            }
        }
        .onChange(of: copyRows.isEmpty && saleRows.isEmpty) { _, empty in if empty { dismiss() } }
    }

    private var deleteTitle: String {
        if case .sale = pendingDelete { return L("sd_delete_sale_title") }
        return L("sd_delete_copy_cd")
    }

    private var emptyBody: some View {
        Text(L("item_details_empty"))
            .font(.subheadline).foregroundStyle(Bw.textMuted)
            .frame(maxWidth: .infinity).padding(.vertical, 28)
    }
}

// MARK: - Tables

/// Table cells in a row: every subview but the last shares the width the last one (fixed, the action
/// column) leaves over, in proportion to `weights` — Compose's `Modifier.weight` for one row.
private struct TableRow: Layout {
    let weights: [CGFloat]
    let trailing: CGFloat
    /// Gap after each weighted column, so neighbouring values never touch.
    private let gap: CGFloat = 6

    private func widths(in total: CGFloat) -> [CGFloat] {
        let free = max(total - trailing - gap * CGFloat(weights.count), 0)
        let sum = max(weights.reduce(0, +), 0.001)
        return weights.map { free * $0 / sum } + [trailing]
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let total = proposal.width ?? 320
        let columns = widths(in: total)
        let height = zip(subviews, columns).map { $0.sizeThatFits(ProposedViewSize(width: $1, height: nil)).height }.max() ?? 0
        return CGSize(width: total, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX
        for (subview, width) in zip(subviews, widths(in: bounds.width)) {
            subview.place(at: CGPoint(x: x, y: bounds.midY), anchor: .leading, proposal: ProposedViewSize(width: width, height: nil))
            x += width + gap
        }
    }
}

private enum TableStyle {
    /// One action button's tap area; the glyph inside is smaller.
    static let action: CGFloat = 28
    static let actionGap: CGFloat = 2
    static func actionsWidth(_ count: Int) -> CGFloat { CGFloat(count) * action + CGFloat(count - 1) * actionGap }

    static func header(_ text: String) -> some View {
        Text(text.uppercased()).font(.system(size: 10, weight: .bold)).tracking(0.4).foregroundStyle(Bw.textMuted)
            .lineLimit(1).minimumScaleFactor(0.7).frame(maxWidth: .infinity, alignment: .leading)
    }

    static func cell(_ text: String, strong: Bool = false, color: Color? = nil) -> some View {
        Text(text).font(.system(size: 11, weight: strong ? .semibold : .regular))
            .foregroundStyle(color ?? (strong ? Bw.text : Bw.textSecondary))
            .lineLimit(1).minimumScaleFactor(0.7).frame(maxWidth: .infinity, alignment: .leading)
    }

    static func total(_ text: String, color: Color = Bw.text) -> some View {
        Text(text).font(.system(size: 12, weight: .bold)).foregroundStyle(color)
            .lineLimit(1).minimumScaleFactor(0.7).frame(maxWidth: .infinity, alignment: .leading)
    }

    static func condition(_ c: Condition) -> String { c == .used ? L("sheet_condition_used") : L("sheet_condition_new") }
}

/// One row action: an icon in a tap area a thumb can hit.
private struct RowAction<Icon: View>: View {
    let label: String
    let action: () -> Void
    @ViewBuilder var icon: () -> Icon

    var body: some View {
        Button(action: action) {
            icon().frame(width: TableStyle.action, height: TableStyle.action).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }
}

/// The note toggle, shared by both tables: tinted when the row has a note to show.
private struct NoteAction: View {
    let hasNote: Bool
    let toggle: () -> Void

    var body: some View {
        RowAction(label: L("sd_toggle_note_cd"), action: toggle) {
            Image(systemName: "note.text").font(.system(size: 15, weight: .medium))
                .foregroundStyle(hasNote ? Bw.link : Bw.borderStrong)
        }
        .disabled(!hasNote)
    }
}

/// The owned copies of one item: Cond. · Date · Qty · Paid, then note / edit / sell / delete per copy,
/// and an Avg row. (Internal so it can be rendered on its own.)
struct ItemCopiesTable: View {
    let item: CollectionItem
    let currency: AppCurrency
    let allowSell: Bool
    @Binding var expanded: Set<String>
    var onEdit: (OwnedCopy) -> Void = { _ in }
    var onSell: (OwnedCopy) -> Void = { _ in }
    var onDelete: (OwnedCopy) -> Void = { _ in }

    private let weights: [CGFloat] = [1, 1.45, 0.45, 1.4]
    private var actionsWidth: CGFloat { TableStyle.actionsWidth(allowSell ? 4 : 3) }

    var body: some View {
        VStack(spacing: 0) {
            TableRow(weights: weights, trailing: actionsWidth) {
                TableStyle.header(L("sd_cond"))
                TableStyle.header(L("sd_date"))
                TableStyle.header(L("sd_qty"))
                TableStyle.header(L("price_paid"))
                Color.clear.frame(height: 1)
            }
            .padding(.bottom, 6)
            Divider().overlay(Bw.borderSoft)

            ForEach(Array(item.copies.enumerated()), id: \.element.id) { index, copy in
                let note = copy.note?.nilIfBlank
                TableRow(weights: weights, trailing: actionsWidth) {
                    TableStyle.cell(TableStyle.condition(copy.condition))
                    TableStyle.cell(copy.dateAdded.isEmpty ? "—" : copy.dateAdded)
                    TableStyle.cell(String(copy.qty))
                    TableStyle.cell(Money.format(copy.pricePaid, from: copy.currency, to: currency), strong: true)
                    HStack(spacing: TableStyle.actionGap) {
                        NoteAction(hasNote: note != nil) { expanded.formSymmetricDifference([copy.id]) }
                        RowAction(label: L("sd_edit_copy_cd"), action: { onEdit(copy) }) {
                            Image(systemName: "pencil").font(.system(size: 15, weight: .medium)).foregroundStyle(Bw.textMuted2)
                        }
                        if allowSell {
                            // Nothing to sell on an empty (0-quantity) copy: the slot stays, the button doesn't.
                            RowAction(label: L("sd_sell_copy_cd"), action: { onSell(copy) }) {
                                Text(verbatim: "$").font(.system(size: 12, weight: .bold)).foregroundStyle(Bw.onYellow)
                                    .frame(width: 21, height: 21).background(Bw.yellow, in: Circle())
                            }
                            .opacity(copy.qty > 0 ? 1 : 0)
                            .disabled(copy.qty <= 0)
                        }
                        RowAction(label: L("sd_delete_copy_cd"), action: { onDelete(copy) }) {
                            Image(systemName: "trash").font(.system(size: 14, weight: .medium)).foregroundStyle(Bw.error)
                        }
                    }
                }
                .padding(.vertical, 5)
                if let note, expanded.contains(copy.id) {
                    Text(note).font(.system(size: 12)).foregroundStyle(Bw.textSecondary)
                        .frame(maxWidth: .infinity, alignment: .leading).padding(.bottom, 8)
                }
                if index < item.copies.count - 1 { Divider().overlay(Bw.borderSoft) }
            }

            Divider().overlay(Bw.borderStrong)
            TableRow(weights: weights, trailing: actionsWidth) {
                TableStyle.total(L("sd_avg"))
                Color.clear.frame(height: 1)
                TableStyle.total(String(item.totalQty))
                TableStyle.total(Money.formatIn(item.avgPaid(in: currency), currency))
                Color.clear.frame(height: 1)
            }
            .padding(.top, 9)
        }
    }
}

/// The sales of one item: Cond. · Date · Qty · Paid · Sale, then note / edit / delete per sale, and a
/// Profit row.
struct ItemSalesTable: View {
    let sales: [SoldItem]
    let currency: AppCurrency
    @Binding var expanded: Set<String>
    var onEdit: (SoldItem) -> Void = { _ in }
    var onDelete: (SoldItem) -> Void = { _ in }

    private let weights: [CGFloat] = [1, 1.45, 0.45, 1.3, 1.3]
    private let actionsWidth = TableStyle.actionsWidth(3)

    var body: some View {
        // Summed in the display currency (each sale converted from its own), like the per-row figures.
        let profit = sales.reduce(Int64(0)) { $0 + CurrencyConverter.shared.convert($1.profit, from: $1.currency, to: currency) }
        VStack(spacing: 0) {
            TableRow(weights: weights, trailing: actionsWidth) {
                TableStyle.header(L("sd_cond"))
                TableStyle.header(L("sd_date"))
                TableStyle.header(L("sd_qty"))
                TableStyle.header(L("price_paid"))
                TableStyle.header(L("price_sale"))
                Color.clear.frame(height: 1)
            }
            .padding(.bottom, 6)
            Divider().overlay(Bw.borderSoft)

            ForEach(Array(sales.enumerated()), id: \.element.id) { index, sale in
                let note = sale.note?.nilIfBlank
                TableRow(weights: weights, trailing: actionsWidth) {
                    TableStyle.cell(TableStyle.condition(sale.condition))
                    TableStyle.cell(sale.soldOn ?? "—")
                    TableStyle.cell(String(sale.quantity))
                    TableStyle.cell(Money.format(sale.pricePaid, from: sale.currency, to: currency))
                    TableStyle.cell(Money.format(sale.saleValue, from: sale.currency, to: currency), strong: true)
                    HStack(spacing: TableStyle.actionGap) {
                        NoteAction(hasNote: note != nil) { expanded.formSymmetricDifference([sale.id]) }
                        RowAction(label: L("sheet_edit_sale"), action: { onEdit(sale) }) {
                            Image(systemName: "pencil").font(.system(size: 15, weight: .medium)).foregroundStyle(Bw.textMuted2)
                        }
                        RowAction(label: L("action_delete"), action: { onDelete(sale) }) {
                            Image(systemName: "trash").font(.system(size: 14, weight: .medium)).foregroundStyle(Bw.error)
                        }
                    }
                }
                .padding(.vertical, 5)
                if let note, expanded.contains(sale.id) {
                    Text(note).font(.system(size: 12)).foregroundStyle(Bw.textSecondary)
                        .frame(maxWidth: .infinity, alignment: .leading).padding(.bottom, 8)
                }
                if index < sales.count - 1 { Divider().overlay(Bw.borderSoft) }
            }

            Divider().overlay(Bw.borderStrong)
            // Totals sit under their columns: quantity sold under Qty, profit under Sale.
            TableRow(weights: weights, trailing: actionsWidth) {
                TableStyle.total(L("sales_profit_label"))
                Color.clear.frame(height: 1)
                TableStyle.total(String(sales.reduce(0) { $0 + $1.quantity }))
                Color.clear.frame(height: 1)
                TableStyle.total((profit > 0 ? "+" : "") + Money.formatIn(profit, currency), color: profit >= 0 ? Bw.success : Bw.error)
                Color.clear.frame(height: 1)
            }
            .padding(.top, 9)
        }
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
            status: sale.status, imageUrl: sale.imageUrl, boxImageUrl: sale.boxImageUrl,
            thumbnailUrl: sale.imageUrl, setId: sale.setId
        )
    }

    init(_ wish: WishlistEntry) {
        self.init(
            setNumber: wish.setNumber, name: wish.name, itemType: wish.itemType, theme: wish.theme,
            releaseYear: wish.releaseYear, releaseMonth: wish.releaseMonth, pieces: wish.pieces,
            minifigs: wish.minifigs, retailPrice: wish.retailPrice > 0 ? wish.retailPrice : nil,
            status: wish.status, imageUrl: wish.imageUrl, boxImageUrl: wish.boxImageUrl,
            thumbnailUrl: wish.imageUrl, setId: wish.setId
        )
    }
}

/// Full-screen swipeable gallery. Candidates that fail to load are dropped. With more than one image, a
/// strip of thumbnails sits at the bottom to jump between them (Android's `ImageGalleryDialog`); it
/// replaces the page dots.
struct ImageGallery: View {
    let urls: [String]
    @Environment(\.dismiss) private var dismiss
    @State private var failed = Set<String>()
    @State private var selection: String?

    init(urls: [String], start: String? = nil) {
        self.urls = urls
        _selection = State(initialValue: start.flatMap { urls.contains($0) ? $0 : nil })
    }

    private var visible: [String] { urls.filter { !failed.contains($0) } }
    /// The image on screen (`selection` is nil until the user swipes or taps a thumbnail).
    private var current: String? { selection.flatMap { visible.contains($0) ? $0 : nil } ?? visible.first }

    var body: some View {
        let visible = visible
        let showsStrip = visible.count > 1
        ZStack(alignment: .topTrailing) {
            Color.black.ignoresSafeArea()
            TabView(selection: $selection) {
                ForEach(visible, id: \.self) { url in
                    RemoteImage([url], maxPointSize: 900) { ok in if !ok { failed.insert(url) } }
                        .padding(.horizontal, 12)
                        // Keep the image clear of the close button and the thumbnail strip.
                        .padding(.top, 56).padding(.bottom, showsStrip ? 96 : 12)
                        .tag(Optional(url))
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .never))

            Button { dismiss() } label: {
                Image(systemName: "xmark").font(.headline).foregroundStyle(.white)
                    .padding(11).background(.white.opacity(0.18), in: Circle())
            }
            .padding(16)
            .accessibilityLabel(L("action_close"))
        }
        .overlay(alignment: .bottom) {
            if showsStrip { thumbnails(visible).padding(.bottom, 28) }
        }
        .onChange(of: visible.isEmpty) { _, empty in if empty { dismiss() } }
    }

    private func thumbnails(_ visible: [String]) -> some View {
        HStack(spacing: 10) {
            ForEach(visible, id: \.self) { url in
                let selected = url == current
                let shape = RoundedRectangle(cornerRadius: 8, style: .continuous)
                Button { withAnimation(.snappy) { selection = url } } label: {
                    // The small thumb where one exists (a Rebrickable render), else the image itself.
                    RemoteImage([CatalogImages.thumbFromRender(url), url], maxPointSize: 54)
                        .padding(4)
                        .frame(width: 54, height: 54)
                        .background(Color.white, in: shape)
                        .clipShape(shape)
                        .overlay(shape.strokeBorder(selected ? Bw.yellow : Color.white.opacity(0.33), lineWidth: selected ? 2 : 1))
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
        }
    }
}

struct GalleryRequest: Identifiable {
    let id = UUID()
    var urls: [String]
    /// The image to open at; nil = the first.
    var start: String?
}
