import SwiftUI

/// What the Add/Edit sheet is opened for. Identifiable so it can drive `.sheet(item:)`.
struct AddSheetRequest: Identifiable {
    enum Mode {
        /// Add a copy (optionally switchable to Sales). `item` nil → start with the set-number lookup.
        case add(salesMode: Bool, allowSalesMode: Bool)
        case editCopy(OwnedCopy)
        case editSale(SoldItem)
    }

    let id = UUID()
    var item: CatalogSet?
    var mode: Mode

    static func add(_ item: CatalogSet?, salesMode: Bool = false, allowSalesMode: Bool = true) -> AddSheetRequest {
        AddSheetRequest(item: item, mode: .add(salesMode: salesMode, allowSalesMode: allowSalesMode))
    }
}

/// The shared Add / Edit sheet for collection copies and sales.
///
/// Money is typed in the **display currency** and stored as typed (never converted at input). Editing
/// therefore *re-bases* an entry: a USD copy edited while displaying ₫ is saved as ₫ — same as Android.
struct AddToCollectionSheet: View {
    let request: AddSheetRequest
    /// Fired after a successful add (not for edits) with the item + whether it went to Sales.
    var onAdded: ((CatalogSet, _ toSales: Bool) -> Void)?

    @Environment(\.dismiss) private var dismiss
    @Environment(AppSettings.self) private var settings
    @Environment(CollectionService.self) private var collection

    @State private var selected: CatalogSet?
    @State private var salesMode = false
    @State private var paid = ""
    @State private var salePrice = ""
    /// Set once the USER types an amount, so the retail prefill stops following the item / quantity.
    @State private var paidEdited = false
    @State private var saleEdited = false
    @State private var qty = "1"
    @State private var condition: Condition = .new
    @State private var date = Date()
    @State private var note = ""

    @State private var query = ""
    @State private var suggestions: [CatalogSet] = []
    @FocusState private var focus: Field?

    private enum Field { case lookup, paid, sale, qty, note }

    private var currency: AppCurrency { settings.currency }

    private var isEdit: Bool {
        if case .add = request.mode { return false }
        return true
    }

    private var isSaleEdit: Bool {
        if case .editSale = request.mode { return true }
        return false
    }

    private var allowSalesToggle: Bool {
        if case .add(_, let allow) = request.mode { return allow }
        return false
    }

    private var title: String {
        if isSaleEdit { return L("sheet_edit_sale") }
        if isEdit { return L("sheet_edit_item") }
        return salesMode ? L("action_add_to_sales") : L("action_add_to_collection")
    }

    private var primaryLabel: String {
        isEdit ? L("sheet_save") : (salesMode ? L("sheet_add_sale") : L("sheet_add_item"))
    }

    private var canSubmit: Bool {
        selected != nil && !paid.isEmpty && (!salesMode || !salePrice.isEmpty)
    }

    var body: some View {
        NavigationStack {
            Form {
                if allowSalesToggle {
                    Picker("", selection: $salesMode) {
                        Text(L("sheet_mode_collection")).tag(false)
                        Text(L("sheet_mode_sales")).tag(true)
                    }
                    .pickerStyle(.segmented)
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets())
                }

                itemSection

                if selected != nil {
                    Section {
                        moneyField(L("sheet_field_paid"), text: typed($paid, edited: $paidEdited), field: .paid)
                        if salesMode {
                            moneyField(L("sheet_field_sale_price"), text: typed($salePrice, edited: $saleEdited), field: .sale)
                        }
                        LabeledContent(L("sheet_field_qty")) {
                            TextField("1", text: $qty)
                                .keyboardType(.numberPad)
                                .multilineTextAlignment(.trailing)
                                .focused($focus, equals: .qty)
                                .onChange(of: qty) { _, new in
                                    let clean = String(new.filter(\.isNumber).prefix(4))
                                    if clean != new { qty = clean } else { rescalePrefill() }
                                }
                        }
                        Picker(L("sheet_field_condition"), selection: $condition) {
                            Text(L("sheet_condition_new")).tag(Condition.new)
                            Text(L("sheet_condition_used")).tag(Condition.used)
                        }
                        DatePicker(
                            salesMode ? L("sheet_field_date_sold") : L("sheet_field_date_added"),
                            selection: $date, in: ...Date.distantFuture, displayedComponents: .date
                        )
                    }
                    Section(L("sheet_field_note")) {
                        TextField(L("sheet_note_optional"), text: $note, axis: .vertical)
                            .lineLimit(3...6)
                            .focused($focus, equals: .note)
                            // The server rejects a longer note; cap it where it's typed, not silently on save.
                            .onChange(of: note) { _, new in
                                if let capped = UserDataLimits.capNote(new), capped != new { note = capped }
                            }
                    }
                }
            }
            .scrollDismissesKeyboard(.interactively)
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button(L("action_cancel")) { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(primaryLabel, action: submit).fontWeight(.semibold).disabled(!canSubmit)
                }
            }
        }
        .presentationDetents([.large])
        .onAppear(perform: seed)
        // A freshly-picked item prefills blank prices from retail.
        .onChange(of: selected) { _, new in if let new { prefillFromRetail(new) } }
        .onChange(of: salesMode) { _, _ in if let selected { prefillFromRetail(selected) } }
        .task(id: query) { await lookup() }
    }

    // MARK: Item section (selected chip, or the set-number lookup)

    @ViewBuilder private var itemSection: some View {
        if let item = selected {
            Section {
                HStack(spacing: 12) {
                    ItemThumb(urls: item.cardImageUrls, size: 52)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(verbatim: "\(item.setNumber) \(item.name)").font(.subheadline.weight(.bold)).lineLimit(2)
                        if !item.theme.isEmpty { Text(item.theme).font(.caption).foregroundStyle(Bw.textMuted) }
                    }
                    Spacer(minLength: 0)
                    if request.item == nil, !isEdit {
                        Button { selected = nil; focus = .lookup } label: {
                            Image(systemName: "xmark.circle.fill").foregroundStyle(Bw.textFaint)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(L("action_remove"))
                    }
                }
            }
        } else {
            Section {
                TextField(L("sheet_enter_set_number"), text: $query)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .focused($focus, equals: .lookup)
                ForEach(suggestions.prefix(6)) { set in
                    Button {
                        selected = set
                        query = ""
                        focus = .paid
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(verbatim: "\(set.setNumber) \(set.name)").font(.subheadline.weight(.semibold)).foregroundStyle(Bw.text)
                            Text(L("sheet_theme_pcs", set.theme, set.pieces)).font(.caption).foregroundStyle(Bw.textMuted)
                        }
                    }
                }
            }
        }
    }

    private func moneyField(_ label: String, text: Binding<String>, field: Field) -> some View {
        LabeledContent(label) {
            HStack(spacing: 3) {
                if currency == .usd { Text(currency.symbol).foregroundStyle(Bw.textMuted) }
                TextField("0", text: text)
                    .keyboardType(currency == .usd ? .decimalPad : .numberPad)
                    .multilineTextAlignment(.trailing)
                    .focused($focus, equals: field)
                    .onChange(of: text.wrappedValue) { _, new in
                        let clean = Money.sanitizeInput(new, currency)
                        if clean != new { text.wrappedValue = clean }
                    }
                if currency == .vnd { Text(currency.symbol).foregroundStyle(Bw.textMuted) }
            }
        }
    }

    // MARK: Logic

    private func seed() {
        selected = request.item
        switch request.mode {
        case .add(let sales, _):
            salesMode = sales
            if let item = request.item { prefillFromRetail(item) } else { focus = .lookup }
        case .editCopy(let copy):
            paid = Money.fieldText(copy.pricePaid, from: copy.currency, to: currency)
            qty = String(copy.qty)
            condition = copy.condition
            date = Self.parse(copy.dateAdded) ?? Date()
            note = copy.note ?? ""
        case .editSale(let sale):
            salesMode = true
            paid = Money.fieldText(sale.pricePaid, from: sale.currency, to: currency)
            salePrice = Money.fieldText(sale.saleValue, from: sale.currency, to: currency)
            qty = String(sale.quantity)
            condition = sale.condition
            date = Self.parse(sale.soldOn) ?? Date()
            note = sale.note ?? ""
        }
    }

    /// A money-field binding that records that the USER changed the amount. Programmatic prefills assign
    /// the state directly and never pass through here.
    private func typed(_ text: Binding<String>, edited: Binding<Bool>) -> Binding<String> {
        Binding(get: { text.wrappedValue }, set: { new in
            guard new != text.wrappedValue else { return }
            text.wrappedValue = new
            edited.wrappedValue = true
        })
    }

    /// Prefill for a newly chosen item / mode: fills an empty field, and replaces a prefill the user never
    /// touched (so it follows the item), but never an amount they typed.
    private func prefillFromRetail(_ item: CatalogSet) {
        guard !isEdit, let text = Money.retailFieldText(item.retailPrice, units: Int(qty) ?? 1, to: currency) else { return }
        if paid.isEmpty || !paidEdited { paid = text }
        if salesMode, salePrice.isEmpty || !saleEdited { salePrice = text }
    }

    /// Keep the retail prefill in step with the quantity — unless the user typed their own amount, or this
    /// is an edit (whose prefill is the stored total, not a retail estimate).
    private func rescalePrefill() {
        guard !isEdit, let item = selected, let units = Int(qty), units > 0,
              let text = Money.retailFieldText(item.retailPrice, units: units, to: currency) else { return }
        if !paidEdited { paid = text }
        if salesMode, !saleEdited { salePrice = text }
    }

    /// Debounced catalog lookup for the typed set number (a bounded server query, not a local scan).
    private func lookup() async {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard selected == nil, !q.isEmpty else { suggestions = []; return }
        do {
            try await Task.sleep(for: .milliseconds(180))
            suggestions = try await CatalogRepository.shared.searchSets(q, limit: 8)
        } catch is CancellationError {
            // a newer keystroke superseded this one — keep the old list
        } catch {
            suggestions = []
        }
    }

    private func submit() {
        guard let item = selected else { return }
        let quantity = max(1, Int(qty) ?? 1)
        let paidAmount = Money.amount(fromInput: paid, currency)
        let saleAmount = Money.amount(fromInput: salePrice, currency)
        let iso = Self.iso(date)
        let noteText = note.nilIfBlank

        switch request.mode {
        case .editSale(let sale):
            collection.updateSale(
                id: sale.id, quantity: quantity, condition: condition, paid: paidAmount,
                salePrice: saleAmount, currency: currency, soldOn: iso, note: noteText
            )
        case .editCopy(let copy):
            collection.updateCopy(id: copy.id, .init(
                condition: condition, qty: quantity, pricePaid: paidAmount, currency: currency, date: iso, note: noteText
            ))
        case .add:
            if salesMode {
                collection.addSale(
                    of: item, qty: quantity, condition: condition, paid: paidAmount,
                    salePrice: saleAmount, currency: currency, soldOn: iso, note: noteText
                )
            } else {
                collection.addCopy(of: item, .init(
                    condition: condition, qty: quantity, pricePaid: paidAmount, currency: currency, date: iso, note: noteText
                ))
            }
            onAdded?(item, salesMode)
        }
        dismiss()
    }

    // Dates are stored as plain ISO days in the user's calendar (Android: LocalDate.now().toString()).
    static func iso(_ date: Date) -> String { LocalDay(date: date).iso }

    static func parse(_ iso: String?) -> Date? {
        guard let day = LocalDay(iso) else { return nil }
        return Calendar.current.date(from: DateComponents(year: day.year, month: day.month, day: day.day))
    }
}

/// Sell `n` units out of an owned copy.
struct SellCopySheet: View {
    let item: CollectionItem
    let copy: OwnedCopy
    var onSold: (() -> Void)?

    @Environment(\.dismiss) private var dismiss
    @Environment(AppSettings.self) private var settings
    @Environment(CollectionService.self) private var collection

    @State private var qty = ""
    @State private var salePrice = ""
    /// Set once the user types a price, so the retail prefill stops following the quantity.
    @State private var saleEdited = false
    @State private var date = Date()

    private var currency: AppCurrency { settings.currency }
    private var maxQty: Int { max(1, copy.qty) }

    /// The sale row stores the TOTAL for the units sold (`sellCopy` prorates the cost by quantity), so the
    /// prefill is retail × quantity — one unit's retail recorded a break-even multi-unit sale as a loss.
    private func retailText(units: Int) -> String? {
        Money.retailFieldText(item.retailPrice, units: units, to: currency)
    }
    private var canSell: Bool { (1...maxQty).contains(Int(qty) ?? 0) && !salePrice.isEmpty }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(verbatim: "\(item.setNumber) \(item.name)").font(.subheadline.weight(.bold))
                        PriceLine(label: L("price_paid"), value: Money.format(copy.pricePaid, from: copy.currency, to: currency))
                    }
                }
                Section {
                    LabeledContent(L("sell_qty", maxQty)) {
                        TextField("1", text: $qty)
                            .keyboardType(.numberPad).multilineTextAlignment(.trailing)
                            .onChange(of: qty) { _, new in
                                let digits = new.filter(\.isNumber)
                                // Values above what's available clamp to the max; blank stays allowed.
                                let clean = Int(digits).map { String(min($0, maxQty)) } ?? ""
                                if clean != new { qty = clean; return }
                                // Keep the retail prefill in step with the quantity until the user edits it.
                                if !saleEdited, let units = Int(clean), units > 0, let text = retailText(units: units) {
                                    salePrice = text
                                }
                            }
                    }
                    LabeledContent(L("sheet_field_sale_price")) {
                        HStack(spacing: 3) {
                            if currency == .usd { Text(currency.symbol).foregroundStyle(Bw.textMuted) }
                            TextField("0", text: Binding(get: { salePrice }, set: { new in
                                guard new != salePrice else { return }
                                salePrice = new
                                saleEdited = true
                            }))
                                .keyboardType(currency == .usd ? .decimalPad : .numberPad)
                                .multilineTextAlignment(.trailing)
                                .onChange(of: salePrice) { _, new in
                                    let clean = Money.sanitizeInput(new, currency)
                                    if clean != new { salePrice = clean }
                                }
                            if currency == .vnd { Text(currency.symbol).foregroundStyle(Bw.textMuted) }
                        }
                    }
                    DatePicker(L("sheet_field_date_sold"), selection: $date, displayedComponents: .date)
                }
            }
            .navigationTitle(L("sell_title"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button(L("action_cancel")) { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(L("sell_confirm")) {
                        collection.sellCopy(
                            id: copy.id, quantity: Int(qty) ?? 1,
                            salePrice: Money.amount(fromInput: salePrice, currency),
                            currency: currency, soldOn: AddToCollectionSheet.iso(date)
                        )
                        onSold?()
                        dismiss()
                    }
                    .fontWeight(.semibold).disabled(!canSell)
                }
            }
        }
        .presentationDetents([.medium, .large])
        .onAppear {
            qty = String(maxQty)
            if let text = retailText(units: maxQty) { salePrice = text }
        }
    }
}
